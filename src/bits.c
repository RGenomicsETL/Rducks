#ifndef R_NO_REMAP
#define R_NO_REMAP
#endif
#include <R.h>
#include <Rinternals.h>

#include "rducks_native.h"

#include <ctype.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>

static int rducks_bits_get_length(SEXP bit_length_sexp) {
    int bit_length = Rf_asInteger(bit_length_sexp);
    if (bit_length == NA_INTEGER || bit_length < 0) Rf_error("bit_length must be a non-negative integer");
    return bit_length;
}

static SEXP rducks_bits_pack_from_int_ptr(const int *bits, R_xlen_t n) {
    R_xlen_t nbytes = rducks_bytes_for_bits(n, "BIT vector");
    SEXP out = PROTECT(Rf_allocVector(RAWSXP, nbytes));
    memset(RAW(out), 0, (size_t)nbytes);
    for (R_xlen_t i = 0; i < n; i++) {
        int value = bits[i];
        if (value == NA_INTEGER || (value != 0 && value != 1)) {
            Rf_error("BIT vector input must contain only 0/1 or TRUE/FALSE values");
        }
        if (value) {
            R_xlen_t byte = i / 8;
            int shift = 7 - (int)(i % 8);
            RAW(out)[byte] = (Rbyte)(RAW(out)[byte] | (Rbyte)(1U << shift));
        }
    }
    UNPROTECT(1);
    return out;
}

SEXP RDUCKS_pack_bits(SEXP bits_sexp) {
    SEXP bits = bits_sexp;
    int protect_bits = 0;
    if (TYPEOF(bits) != INTSXP && TYPEOF(bits) != LGLSXP) {
        bits = PROTECT(Rf_coerceVector(bits_sexp, INTSXP));
        protect_bits = 1;
    }
    R_xlen_t n = XLENGTH(bits);
    SEXP out;
    if (TYPEOF(bits) == LGLSXP || TYPEOF(bits) == INTSXP) {
        out = PROTECT(rducks_bits_pack_from_int_ptr(INTEGER(bits), n));
    } else {
        Rf_error("BIT vector input must contain only 0/1 or TRUE/FALSE values");
    }
    UNPROTECT(1);
    if (protect_bits) UNPROTECT(1);
    return out;
}

SEXP RDUCKS_unpack_bits(SEXP data_sexp, SEXP bit_length_sexp) {
    if (TYPEOF(data_sexp) != RAWSXP) Rf_error("data must be raw");
    int bit_length = rducks_bits_get_length(bit_length_sexp);
    rducks_require_bit_span(data_sexp, 0, (R_xlen_t)bit_length, "BIT");
    SEXP out = PROTECT(Rf_allocVector(INTSXP, bit_length));
    const Rbyte *data = RAW(data_sexp);
    for (int i = 0; i < bit_length; i++) {
        int byte = i / 8;
        int shift = 7 - (i % 8);
        INTEGER(out)[i] = (data[byte] >> shift) & 1U;
    }
    UNPROTECT(1);
    return out;
}

SEXP RDUCKS_bits_to_character(SEXP data_sexp, SEXP bit_length_sexp) {
    if (TYPEOF(data_sexp) != RAWSXP) Rf_error("data must be raw");
    int bit_length = rducks_bits_get_length(bit_length_sexp);
    rducks_require_bit_span(data_sexp, 0, (R_xlen_t)bit_length, "BIT");
    char *buf = (char *)R_alloc((size_t)bit_length + 1U, sizeof(char));
    const Rbyte *data = RAW(data_sexp);
    for (int i = 0; i < bit_length; i++) {
        int byte = i / 8;
        int shift = 7 - (i % 8);
        buf[i] = ((data[byte] >> shift) & 1U) ? '1' : '0';
    }
    buf[bit_length] = '\0';
    SEXP out = PROTECT(Rf_allocVector(STRSXP, 1));
    SET_STRING_ELT(out, 0, Rf_mkCharLenCE(buf, bit_length, CE_UTF8));
    UNPROTECT(1);
    return out;
}

static void rducks_bits_mask_tail(Rbyte *data, int bit_length) {
    R_xlen_t nbytes = rducks_bytes_for_bits((R_xlen_t)bit_length, "BIT");
    int unused = (int)(nbytes * 8 - (R_xlen_t)bit_length);
    if (unused > 0 && bit_length > 0) {
        int last = (bit_length - 1) / 8;
        data[last] = (Rbyte)(data[last] & (Rbyte)(0xffU << unused));
    }
}

SEXP RDUCKS_bits_binary_raw(SEXP a_sexp, SEXP b_sexp, SEXP bit_length_sexp, SEXP op_sexp) {
    if (TYPEOF(a_sexp) != RAWSXP || TYPEOF(b_sexp) != RAWSXP) Rf_error("BIT operands must be raw");
    int bit_length = rducks_bits_get_length(bit_length_sexp);
    R_xlen_t nbytes = rducks_bytes_for_bits((R_xlen_t)bit_length, "BIT");
    if (XLENGTH(a_sexp) < nbytes || XLENGTH(b_sexp) < nbytes) Rf_error("BIT raw storage is shorter than bit length");
    if (TYPEOF(op_sexp) != STRSXP || XLENGTH(op_sexp) != 1 || STRING_ELT(op_sexp, 0) == NA_STRING) Rf_error("op must be a string");
    const char *op = CHAR(STRING_ELT(op_sexp, 0));
    const Rbyte *a = RAW(a_sexp);
    const Rbyte *b = RAW(b_sexp);
    SEXP out = PROTECT(Rf_allocVector(RAWSXP, nbytes));
    Rbyte *dst = RAW(out);
    if (strcmp(op, "&") == 0) {
        for (R_xlen_t i = 0; i < nbytes; i++) dst[i] = (Rbyte)(a[i] & b[i]);
    } else if (strcmp(op, "|") == 0) {
        for (R_xlen_t i = 0; i < nbytes; i++) dst[i] = (Rbyte)(a[i] | b[i]);
    } else if (strcmp(op, "xor") == 0) {
        for (R_xlen_t i = 0; i < nbytes; i++) dst[i] = (Rbyte)(a[i] ^ b[i]);
    } else {
        Rf_error("unsupported BIT operation");
    }
    rducks_bits_mask_tail(dst, bit_length);
    UNPROTECT(1);
    return out;
}

SEXP RDUCKS_bits_not_raw(SEXP data_sexp, SEXP bit_length_sexp) {
    if (TYPEOF(data_sexp) != RAWSXP) Rf_error("data must be raw");
    int bit_length = rducks_bits_get_length(bit_length_sexp);
    R_xlen_t nbytes = rducks_bytes_for_bits((R_xlen_t)bit_length, "BIT");
    if (XLENGTH(data_sexp) < nbytes) Rf_error("BIT raw storage is shorter than bit length");
    SEXP out = PROTECT(Rf_allocVector(RAWSXP, nbytes));
    for (R_xlen_t i = 0; i < nbytes; i++) RAW(out)[i] = (Rbyte)(~RAW(data_sexp)[i]);
    rducks_bits_mask_tail(RAW(out), bit_length);
    UNPROTECT(1);
    return out;
}

SEXP RDUCKS_bits_from_character(SEXP x_sexp) {
    if (TYPEOF(x_sexp) != STRSXP || XLENGTH(x_sexp) != 1 || STRING_ELT(x_sexp, 0) == NA_STRING) {
        Rf_error("character BIT input must be a single non-NA string");
    }
    const char *x = CHAR(STRING_ELT(x_sexp, 0));
    size_t len = strlen(x);
    int bit_length = 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char ch = (unsigned char)x[i];
        if (ch == '_' || isspace(ch)) continue;
        if (ch != '0' && ch != '1') Rf_error("BIT character input may contain only 0 and 1");
        if (bit_length == INT_MAX) Rf_error("BIT value is too long");
        bit_length++;
    }
    if (bit_length == 0) Rf_error("BIT values must contain at least one bit");
    R_xlen_t nbytes = rducks_bytes_for_bits((R_xlen_t)bit_length, "BIT");
    SEXP data = PROTECT(Rf_allocVector(RAWSXP, nbytes));
    memset(RAW(data), 0, (size_t)nbytes);
    int pos = 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char ch = (unsigned char)x[i];
        if (ch == '_' || isspace(ch)) continue;
        if (ch == '1') {
            int byte = pos / 8;
            int shift = 7 - (pos % 8);
            RAW(data)[byte] = (Rbyte)(RAW(data)[byte] | (Rbyte)(1U << shift));
        }
        pos++;
    }
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 2));
    SET_VECTOR_ELT(out, 0, data);
    SET_VECTOR_ELT(out, 1, Rf_ScalarInteger(bit_length));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 2));
    SET_STRING_ELT(names, 0, Rf_mkChar("data"));
    SET_STRING_ELT(names, 1, Rf_mkChar("length"));
    Rf_setAttrib(out, R_NamesSymbol, names);
    UNPROTECT(3);
    return out;
}

static SEXP rducks_bits_named3(SEXP valid, SEXP offsets, SEXP data) {
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 3));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 3));
    SET_VECTOR_ELT(out, 0, valid);
    SET_VECTOR_ELT(out, 1, offsets);
    SET_VECTOR_ELT(out, 2, data);
    SET_STRING_ELT(names, 0, Rf_mkChar("valid"));
    SET_STRING_ELT(names, 1, Rf_mkChar("offsets"));
    SET_STRING_ELT(names, 2, Rf_mkChar("data"));
    Rf_setAttrib(out, R_NamesSymbol, names);
    UNPROTECT(2);
    return out;
}

static SEXP rducks_bits_make_object_from_payload(const Rbyte *payload, int len) {
    if (len < 2) Rf_error("invalid BIT payload");
    int padding = (int)payload[0];
    if (padding < 0 || padding > 7) Rf_error("invalid BIT padding");
    R_xlen_t raw_bits = ((R_xlen_t)len - 1) * 8 - padding;
    if (raw_bits <= 0 || raw_bits > INT_MAX) Rf_error("invalid BIT payload");
    int bit_length = (int)raw_bits;
    R_xlen_t nbytes = rducks_bytes_for_bits((R_xlen_t)bit_length, "BIT");
    SEXP data = PROTECT(Rf_allocVector(RAWSXP, nbytes));
    memset(RAW(data), 0, (size_t)nbytes);
    for (int i = 0; i < bit_length; i++) {
        int storage_bit = padding + i;
        int src_byte = 1 + storage_bit / 8;
        int src_bit = storage_bit % 8;
        int value = (payload[src_byte] >> (7 - src_bit)) & 1U;
        if (value) {
            int dst_byte = i / 8;
            int dst_bit = i % 8;
            RAW(data)[dst_byte] = (Rbyte)(RAW(data)[dst_byte] | (Rbyte)(1U << (7 - dst_bit)));
        }
    }
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 2));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 2));
    SEXP cls = PROTECT(Rf_mkString("rducks_bits"));
    SET_VECTOR_ELT(out, 0, data);
    SET_VECTOR_ELT(out, 1, Rf_ScalarInteger(bit_length));
    SET_STRING_ELT(names, 0, Rf_mkChar("data"));
    SET_STRING_ELT(names, 1, Rf_mkChar("length"));
    Rf_setAttrib(out, R_NamesSymbol, names);
    Rf_setAttrib(out, R_ClassSymbol, cls);
    UNPROTECT(4);
    return out;
}

SEXP RDUCKS_bit_payloads_to_values(SEXP data_sexp, SEXP offsets_sexp, SEXP valid_sexp,
                                   SEXP offset_sexp, SEXP n_sexp) {
    if (TYPEOF(data_sexp) != RAWSXP) Rf_error("data must be raw");
    if (TYPEOF(offsets_sexp) != INTSXP) Rf_error("offsets must be integer");
    if (TYPEOF(valid_sexp) != LGLSXP) Rf_error("valid must be logical");
    int offset = Rf_asInteger(offset_sexp);
    int n = Rf_asInteger(n_sexp);
    if (offset < 0 || n < 0) Rf_error("invalid BIT parameters");
    rducks_require_len(offsets_sexp, rducks_xlen_add(rducks_xlen_add((R_xlen_t)offset, (R_xlen_t)n, "BIT"), 1, "BIT"), "offsets");
    rducks_require_len(valid_sexp, (R_xlen_t)n, "valid");
    SEXP out = PROTECT(Rf_allocVector(VECSXP, n));
    const Rbyte *data = RAW(data_sexp);
    R_xlen_t data_len = XLENGTH(data_sexp);
    for (int i = 0; i < n; i++) {
        if (LOGICAL(valid_sexp)[i] != TRUE) {
            SET_VECTOR_ELT(out, i, R_NilValue);
            continue;
        }
        R_xlen_t idx = (R_xlen_t)offset + i;
        int start = INTEGER(offsets_sexp)[idx];
        int end = INTEGER(offsets_sexp)[idx + 1];
        if (start < 0 || end < start || end > data_len) Rf_error("invalid BIT offsets");
        SEXP one = PROTECT(rducks_bits_make_object_from_payload(data + start, end - start));
        SET_VECTOR_ELT(out, i, one);
        UNPROTECT(1);
    }
    UNPROTECT(1);
    return out;
}

SEXP RDUCKS_bit_values_to_payloads(SEXP values) {
    if (TYPEOF(values) != VECSXP) Rf_error("values must be a list");
    R_xlen_t n = XLENGTH(values);
    if (n > INT_MAX - 1) Rf_error("too many BIT values for packed buffer");
    SEXP valid = PROTECT(Rf_allocVector(LGLSXP, n));
    SEXP offsets = PROTECT(Rf_allocVector(INTSXP, n + 1));
    INTEGER(offsets)[0] = 0;
    R_xlen_t total = 0;
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP value = VECTOR_ELT(values, i);
        if (value == R_NilValue) {
            LOGICAL(valid)[i] = FALSE;
        } else {
            if (TYPEOF(value) != VECSXP || XLENGTH(value) < 2) Rf_error("BIT values must be rducks_bits objects");
            int bit_length = Rf_asInteger(VECTOR_ELT(value, 1));
            if (bit_length <= 0) Rf_error("BIT values must contain at least one bit");
            LOGICAL(valid)[i] = TRUE;
            total = rducks_xlen_add(total, 1 + rducks_bytes_for_bits((R_xlen_t)bit_length, "BIT buffer"), "BIT buffer");
            if (total > INT_MAX) Rf_error("BIT buffer exceeds integer offset range");
        }
        INTEGER(offsets)[i + 1] = (int)total;
    }
    SEXP data = PROTECT(Rf_allocVector(RAWSXP, total));
    memset(RAW(data), 0, (size_t)total);
    R_xlen_t pos = 0;
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP value = VECTOR_ELT(values, i);
        if (value == R_NilValue) continue;
        SEXP bits = VECTOR_ELT(value, 0);
        int bit_length = Rf_asInteger(VECTOR_ELT(value, 1));
        if (TYPEOF(bits) != RAWSXP) Rf_error("BIT value has invalid storage");
        rducks_require_bit_span(bits, 0, (R_xlen_t)bit_length, "BIT value");
        int padding = (8 - (bit_length % 8)) % 8;
        int len = 1 + (int)rducks_bytes_for_bits((R_xlen_t)bit_length, "BIT buffer");
        Rbyte *payload = RAW(data) + pos;
        payload[0] = (Rbyte)padding;
        for (int bit_idx = 0; bit_idx < padding; bit_idx++) {
            payload[1] = (Rbyte)(payload[1] | (Rbyte)(1U << (7 - bit_idx)));
        }
        for (int j = 0; j < bit_length; j++) {
            int src_byte = j / 8;
            int src_bit = j % 8;
            int set = (RAW(bits)[src_byte] >> (7 - src_bit)) & 1U;
            if (set) {
                int storage_bit = padding + j;
                int dst_byte = 1 + storage_bit / 8;
                int dst_bit = storage_bit % 8;
                payload[dst_byte] = (Rbyte)(payload[dst_byte] | (Rbyte)(1U << (7 - dst_bit)));
            }
        }
        pos += len;
    }
    SEXP out = PROTECT(rducks_bits_named3(valid, offsets, data));
    UNPROTECT(4);
    return out;
}
