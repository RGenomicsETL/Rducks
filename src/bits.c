#include <R.h>
#include <Rinternals.h>
#include <stdint.h>
#include <string.h>
#include <ctype.h>

static int rducks_bits_get_length(SEXP bit_length_sexp) {
    int bit_length = Rf_asInteger(bit_length_sexp);
    if (bit_length == NA_INTEGER || bit_length < 0) Rf_error("bit_length must be a non-negative integer");
    return bit_length;
}

static SEXP rducks_bits_pack_from_int_ptr(const int *bits, R_xlen_t n) {
    R_xlen_t nbytes = (n + 7) / 8;
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
    if ((R_xlen_t)bit_length > XLENGTH(data_sexp) * 8) Rf_error("bit_length exceeds raw storage capacity");
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
    if ((R_xlen_t)bit_length > XLENGTH(data_sexp) * 8) Rf_error("bit_length exceeds raw storage capacity");
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
    int unused = ((bit_length + 7) / 8) * 8 - bit_length;
    if (unused > 0 && bit_length > 0) {
        int last = (bit_length - 1) / 8;
        data[last] = (Rbyte)(data[last] & (Rbyte)(0xffU << unused));
    }
}

SEXP RDUCKS_bits_binary_raw(SEXP a_sexp, SEXP b_sexp, SEXP bit_length_sexp, SEXP op_sexp) {
    if (TYPEOF(a_sexp) != RAWSXP || TYPEOF(b_sexp) != RAWSXP) Rf_error("BIT operands must be raw");
    int bit_length = rducks_bits_get_length(bit_length_sexp);
    R_xlen_t nbytes = (bit_length + 7) / 8;
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
    R_xlen_t nbytes = (bit_length + 7) / 8;
    if (XLENGTH(data_sexp) < nbytes) Rf_error("BIT raw storage is shorter than bit length");
    SEXP out = PROTECT(Rf_allocVector(RAWSXP, nbytes));
    for (R_xlen_t i = 0; i < nbytes; i++) RAW(out)[i] = (Rbyte)(~RAW(data_sexp)[i]);
    rducks_bits_mask_tail(RAW(out), bit_length);
    UNPROTECT(1);
    return out;
}

SEXP RDUCKS_arrow_pack_bits(SEXP values_sexp) {
    SEXP values = values_sexp;
    int protect_values = 0;
    if (TYPEOF(values) != LGLSXP) {
        values = PROTECT(Rf_coerceVector(values_sexp, LGLSXP));
        protect_values = 1;
    }
    R_xlen_t n = XLENGTH(values);
    R_xlen_t nbytes = (n + 7) / 8;
    SEXP out = PROTECT(Rf_allocVector(RAWSXP, nbytes));
    memset(RAW(out), 0, (size_t)nbytes);
    const int *logical = LOGICAL(values);
    for (R_xlen_t i = 0; i < n; i++) {
        if (logical[i] == TRUE) {
            R_xlen_t byte = i / 8;
            int shift = (int)(i % 8);
            RAW(out)[byte] = (Rbyte)(RAW(out)[byte] | (Rbyte)(1U << shift));
        }
    }
    UNPROTECT(1);
    if (protect_values) UNPROTECT(1);
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
        bit_length++;
    }
    if (bit_length == 0) Rf_error("BIT values must contain at least one bit");
    R_xlen_t nbytes = (bit_length + 7) / 8;
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
