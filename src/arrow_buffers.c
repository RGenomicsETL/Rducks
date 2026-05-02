#ifndef R_NO_REMAP
#define R_NO_REMAP
#endif
#include <R.h>
#include <Rinternals.h>

#include <stdint.h>
#include <string.h>

static SEXP rducks_ab_named3(SEXP a, SEXP b, SEXP c, const char *an, const char *bn, const char *cn) {
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 3));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 3));
    SET_VECTOR_ELT(out, 0, a);
    SET_VECTOR_ELT(out, 1, b);
    SET_VECTOR_ELT(out, 2, c);
    SET_STRING_ELT(names, 0, Rf_mkChar(an));
    SET_STRING_ELT(names, 1, Rf_mkChar(bn));
    SET_STRING_ELT(names, 2, Rf_mkChar(cn));
    Rf_setAttrib(out, R_NamesSymbol, names);
    UNPROTECT(2);
    return out;
}

SEXP RDUCKS_arrow_bool_to_logical(SEXP bytes_sexp, SEXP valid_sexp, SEXP offset_sexp, SEXP n_sexp, SEXP bool8_sexp) {
    if (TYPEOF(bytes_sexp) != RAWSXP) Rf_error("bytes must be raw");
    if (TYPEOF(valid_sexp) != LGLSXP) Rf_error("valid must be logical");
    int offset = Rf_asInteger(offset_sexp);
    int n = Rf_asInteger(n_sexp);
    int bool8 = Rf_asLogical(bool8_sexp) == TRUE;
    if (offset < 0 || n < 0) Rf_error("invalid boolean Arrow parameters");
    SEXP out = PROTECT(Rf_allocVector(LGLSXP, n));
    const Rbyte *bytes = RAW(bytes_sexp);
    R_xlen_t nbytes = XLENGTH(bytes_sexp);
    int byte_per_value = 0;
    if (bool8 && nbytes >= (R_xlen_t)offset + n) {
        byte_per_value = 1;
        for (int i = 0; i < n; i++) {
            Rbyte b = bytes[offset + i];
            if (b != 0 && b != 1) {
                byte_per_value = 0;
                break;
            }
        }
    }
    for (int i = 0; i < n; i++) {
        if (LOGICAL(valid_sexp)[i] != TRUE) {
            LOGICAL(out)[i] = NA_LOGICAL;
            continue;
        }
        if (byte_per_value) {
            LOGICAL(out)[i] = bytes[offset + i] != 0;
        } else {
            int bit = offset + i;
            int byte_index = bit / 8;
            int bit_index = bit % 8;
            if (byte_index >= nbytes) Rf_error("boolean Arrow buffer is too short");
            LOGICAL(out)[i] = (bytes[byte_index] & (Rbyte)(1U << bit_index)) != 0;
        }
    }
    UNPROTECT(1);
    return out;
}

SEXP RDUCKS_arrow_integer_storage_to_values(SEXP bytes_sexp, SEXP valid_sexp, SEXP offset_sexp, SEXP n_sexp,
                                            SEXP width_sexp, SEXP signed_sexp, SEXP numeric_sexp) {
    if (TYPEOF(bytes_sexp) != RAWSXP) Rf_error("bytes must be raw");
    if (TYPEOF(valid_sexp) != LGLSXP) Rf_error("valid must be logical");
    int offset = Rf_asInteger(offset_sexp);
    int n = Rf_asInteger(n_sexp);
    int width = Rf_asInteger(width_sexp);
    int signed_flag = Rf_asLogical(signed_sexp) == TRUE;
    int numeric = Rf_asLogical(numeric_sexp) == TRUE;
    if (offset < 0 || n < 0 || !(width == 1 || width == 2 || width == 4)) Rf_error("invalid integer Arrow parameters");
    if (XLENGTH(bytes_sexp) < (R_xlen_t)(offset + n) * width) Rf_error("integer Arrow buffer is too short");
    SEXP out = PROTECT(Rf_allocVector(numeric ? REALSXP : INTSXP, n));
    const Rbyte *bytes = RAW(bytes_sexp);
    for (int i = 0; i < n; i++) {
        if (LOGICAL(valid_sexp)[i] != TRUE) {
            if (numeric) REAL(out)[i] = NA_REAL; else INTEGER(out)[i] = NA_INTEGER;
            continue;
        }
        const Rbyte *src = bytes + (R_xlen_t)(offset + i) * width;
        uint32_t u = 0;
        for (int j = width - 1; j >= 0; j--) u = (u << 8) | (uint32_t)src[j];
        double value;
        if (signed_flag) {
            if (width == 1) value = (double)(int8_t)u;
            else if (width == 2) value = (double)(int16_t)u;
            else value = (double)(int32_t)u;
        } else {
            value = (double)u;
        }
        if (numeric) REAL(out)[i] = value;
        else INTEGER(out)[i] = (int)value;
    }
    UNPROTECT(1);
    return out;
}

SEXP RDUCKS_arrow_integer_storage_from_values(SEXP values_sexp, SEXP width_sexp, SEXP signed_sexp) {
    SEXP values = PROTECT(Rf_coerceVector(values_sexp, REALSXP));
    int width = Rf_asInteger(width_sexp);
    int signed_flag = Rf_asLogical(signed_sexp) == TRUE;
    if (!(width == 1 || width == 2 || width == 4)) Rf_error("invalid integer Arrow storage width");
    R_xlen_t n = XLENGTH(values);
    SEXP out = PROTECT(Rf_allocVector(RAWSXP, n * width));
    memset(RAW(out), 0, (size_t)(n * width));
    double full_range = width == 1 ? 256.0 : (width == 2 ? 65536.0 : 4294967296.0);
    for (R_xlen_t i = 0; i < n; i++) {
        double value = REAL(values)[i];
        if (ISNA(value) || ISNAN(value)) value = 0;
        if (signed_flag && value < 0) value += full_range;
        uint32_t u = (uint32_t)value;
        Rbyte *dst = RAW(out) + i * width;
        for (int j = 0; j < width; j++) {
            dst[j] = (Rbyte)(u & 0xffU);
            u >>= 8;
        }
    }
    UNPROTECT(2);
    return out;
}

SEXP RDUCKS_arrow_string_array_to_character(SEXP data_sexp, SEXP offsets_sexp, SEXP valid_sexp,
                                            SEXP offset_sexp, SEXP n_sexp) {
    if (TYPEOF(data_sexp) != RAWSXP) Rf_error("data must be raw");
    if (TYPEOF(offsets_sexp) != INTSXP) Rf_error("offsets must be integer");
    if (TYPEOF(valid_sexp) != LGLSXP) Rf_error("valid must be logical");
    int offset = Rf_asInteger(offset_sexp);
    int n = Rf_asInteger(n_sexp);
    if (offset < 0 || n < 0 || XLENGTH(offsets_sexp) < offset + n + 1) Rf_error("invalid string Arrow parameters");
    SEXP out = PROTECT(Rf_allocVector(STRSXP, n));
    const Rbyte *data = RAW(data_sexp);
    R_xlen_t data_len = XLENGTH(data_sexp);
    for (int i = 0; i < n; i++) {
        if (LOGICAL(valid_sexp)[i] != TRUE) {
            SET_STRING_ELT(out, i, NA_STRING);
            continue;
        }
        int start = INTEGER(offsets_sexp)[offset + i];
        int end = INTEGER(offsets_sexp)[offset + i + 1];
        if (start < 0 || end < start || end > data_len) Rf_error("invalid string Arrow offsets");
        SET_STRING_ELT(out, i, Rf_mkCharLenCE((const char *)data + start, end - start, CE_UTF8));
    }
    UNPROTECT(1);
    return out;
}

SEXP RDUCKS_arrow_binary_array_to_values(SEXP data_sexp, SEXP offsets_sexp, SEXP valid_sexp,
                                         SEXP offset_sexp, SEXP n_sexp) {
    if (TYPEOF(data_sexp) != RAWSXP) Rf_error("data must be raw");
    if (TYPEOF(offsets_sexp) != INTSXP) Rf_error("offsets must be integer");
    if (TYPEOF(valid_sexp) != LGLSXP) Rf_error("valid must be logical");
    int offset = Rf_asInteger(offset_sexp);
    int n = Rf_asInteger(n_sexp);
    if (offset < 0 || n < 0 || XLENGTH(offsets_sexp) < offset + n + 1) Rf_error("invalid binary Arrow parameters");
    SEXP out = PROTECT(Rf_allocVector(VECSXP, n));
    const Rbyte *data = RAW(data_sexp);
    R_xlen_t data_len = XLENGTH(data_sexp);
    for (int i = 0; i < n; i++) {
        if (LOGICAL(valid_sexp)[i] != TRUE) {
            SET_VECTOR_ELT(out, i, R_NilValue);
            continue;
        }
        int start = INTEGER(offsets_sexp)[offset + i];
        int end = INTEGER(offsets_sexp)[offset + i + 1];
        if (start < 0 || end < start || end > data_len) Rf_error("invalid binary Arrow offsets");
        SEXP one = PROTECT(Rf_allocVector(RAWSXP, end - start));
        if (end > start) memcpy(RAW(one), data + start, (size_t)(end - start));
        SET_VECTOR_ELT(out, i, one);
        UNPROTECT(1);
    }
    UNPROTECT(1);
    return out;
}

SEXP RDUCKS_arrow_string_array_from_character(SEXP values_sexp) {
    SEXP values = PROTECT(Rf_coerceVector(values_sexp, STRSXP));
    R_xlen_t n = XLENGTH(values);
    if (n > INT_MAX - 1) Rf_error("too many strings for Arrow buffer");
    SEXP valid = PROTECT(Rf_allocVector(LGLSXP, n));
    SEXP offsets = PROTECT(Rf_allocVector(INTSXP, n + 1));
    INTEGER(offsets)[0] = 0;
    R_xlen_t total = 0;
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP ch = STRING_ELT(values, i);
        if (ch == NA_STRING) {
            LOGICAL(valid)[i] = FALSE;
        } else {
            LOGICAL(valid)[i] = TRUE;
            const char *ptr = Rf_translateCharUTF8(ch);
            total += (R_xlen_t)strlen(ptr);
            if (total > INT_MAX) Rf_error("string Arrow buffer exceeds integer offset range");
        }
        INTEGER(offsets)[i + 1] = (int)total;
    }
    SEXP data = PROTECT(Rf_allocVector(RAWSXP, total));
    R_xlen_t pos = 0;
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP ch = STRING_ELT(values, i);
        if (ch == NA_STRING) continue;
        const char *ptr = Rf_translateCharUTF8(ch);
        size_t len = strlen(ptr);
        if (len) memcpy(RAW(data) + pos, ptr, len);
        pos += (R_xlen_t)len;
    }
    SEXP out = PROTECT(rducks_ab_named3(valid, offsets, data, "valid", "offsets", "data"));
    UNPROTECT(5);
    return out;
}

SEXP RDUCKS_arrow_binary_payload_array(SEXP payloads) {
    if (TYPEOF(payloads) != VECSXP) Rf_error("payloads must be a list");
    R_xlen_t n = XLENGTH(payloads);
    if (n > INT_MAX - 1) Rf_error("too many payloads for Arrow buffer");
    SEXP valid = PROTECT(Rf_allocVector(LGLSXP, n));
    SEXP offsets = PROTECT(Rf_allocVector(INTSXP, n + 1));
    INTEGER(offsets)[0] = 0;
    R_xlen_t total = 0;
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP one = VECTOR_ELT(payloads, i);
        if (one == R_NilValue) {
            LOGICAL(valid)[i] = FALSE;
        } else {
            if (TYPEOF(one) != RAWSXP) Rf_error("payloads must contain raw vectors or NULL");
            LOGICAL(valid)[i] = TRUE;
            total += XLENGTH(one);
            if (total > INT_MAX) Rf_error("binary Arrow buffer exceeds integer offset range");
        }
        INTEGER(offsets)[i + 1] = (int)total;
    }
    SEXP data = PROTECT(Rf_allocVector(RAWSXP, total));
    R_xlen_t pos = 0;
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP one = VECTOR_ELT(payloads, i);
        if (one == R_NilValue) continue;
        R_xlen_t len = XLENGTH(one);
        if (len) memcpy(RAW(data) + pos, RAW(one), (size_t)len);
        pos += len;
    }
    SEXP out = PROTECT(rducks_ab_named3(valid, offsets, data, "valid", "offsets", "data"));
    UNPROTECT(4);
    return out;
}

SEXP RDUCKS_arrow_i64_micros_to_seconds(SEXP bytes_sexp, SEXP valid_sexp, SEXP offset_sexp, SEXP n_sexp) {
    if (TYPEOF(bytes_sexp) != RAWSXP) Rf_error("bytes must be raw");
    if (TYPEOF(valid_sexp) != LGLSXP) Rf_error("valid must be logical");
    int offset = Rf_asInteger(offset_sexp);
    int n = Rf_asInteger(n_sexp);
    if (offset < 0 || n < 0) Rf_error("invalid int64 Arrow parameters");
    if (XLENGTH(bytes_sexp) < (R_xlen_t)(offset + n) * 8) Rf_error("int64 Arrow buffer is too short");
    SEXP out = PROTECT(Rf_allocVector(REALSXP, n));
    const Rbyte *bytes = RAW(bytes_sexp);
    for (int i = 0; i < n; i++) {
        if (LOGICAL(valid_sexp)[i] != TRUE) {
            REAL(out)[i] = NA_REAL;
            continue;
        }
        const Rbyte *src = bytes + (R_xlen_t)(offset + i) * 8;
        uint64_t u = 0;
        for (int j = 7; j >= 0; j--) u = (u << 8) | (uint64_t)src[j];
        int64_t v;
        memcpy(&v, &u, sizeof(v));
        REAL(out)[i] = (double)v / 1000000.0;
    }
    UNPROTECT(1);
    return out;
}

SEXP RDUCKS_arrow_i64_storage_from_numeric(SEXP values_sexp) {
    SEXP values = PROTECT(Rf_coerceVector(values_sexp, REALSXP));
    R_xlen_t n = XLENGTH(values);
    SEXP out = PROTECT(Rf_allocVector(RAWSXP, n * 8));
    memset(RAW(out), 0, (size_t)(n * 8));
    for (R_xlen_t i = 0; i < n; i++) {
        double d = REAL(values)[i];
        int64_t v = (ISNA(d) || ISNAN(d)) ? 0 : (int64_t)d;
        uint64_t u;
        memcpy(&u, &v, sizeof(u));
        Rbyte *dst = RAW(out) + i * 8;
        for (int j = 0; j < 8; j++) dst[j] = (Rbyte)((u >> (8 * j)) & 0xffU);
    }
    UNPROTECT(2);
    return out;
}
