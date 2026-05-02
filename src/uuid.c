#include <R.h>
#include <Rinternals.h>
#include <stdint.h>
#include <string.h>
#include <ctype.h>

static int rducks_uuid_hex_value(unsigned char ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return 10 + ch - 'a';
    if (ch >= 'A' && ch <= 'F') return 10 + ch - 'A';
    return -1;
}

SEXP RDUCKS_uuid_bytes_from_strings(SEXP values_sexp) {
    SEXP values = values_sexp;
    int protect_values = 0;
    if (TYPEOF(values) != STRSXP) {
        values = PROTECT(Rf_coerceVector(values_sexp, STRSXP));
        protect_values = 1;
    }
    R_xlen_t n = XLENGTH(values);
    SEXP out = PROTECT(Rf_allocVector(RAWSXP, n * 16));
    memset(RAW(out), 0, (size_t)(n * 16));
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP ch = STRING_ELT(values, i);
        if (ch == NA_STRING) continue;
        const char *s = CHAR(ch);
        unsigned char hex[32];
        int h = 0;
        for (size_t j = 0; s[j] != '\0'; j++) {
            unsigned char c = (unsigned char)s[j];
            if (c == '-') continue;
            int v = rducks_uuid_hex_value(c);
            if (v < 0 || h >= 32) Rf_error("invalid UUID value");
            hex[h++] = (unsigned char)v;
        }
        if (h != 32) Rf_error("invalid UUID value");
        Rbyte *dst = RAW(out) + i * 16;
        for (int j = 0; j < 16; j++) dst[j] = (Rbyte)((hex[2 * j] << 4) | hex[2 * j + 1]);
    }
    UNPROTECT(1);
    if (protect_values) UNPROTECT(1);
    return out;
}

SEXP RDUCKS_uuid_strings_from_bytes(SEXP bytes_sexp, SEXP valid_sexp, SEXP offset_sexp, SEXP n_sexp) {
    if (TYPEOF(bytes_sexp) != RAWSXP) Rf_error("bytes must be raw");
    if (TYPEOF(valid_sexp) != LGLSXP) Rf_error("valid must be logical");
    int offset = Rf_asInteger(offset_sexp);
    int n = Rf_asInteger(n_sexp);
    if (offset < 0 || n < 0) Rf_error("invalid UUID conversion parameters");
    if (XLENGTH(bytes_sexp) < (R_xlen_t)(offset + n) * 16) Rf_error("UUID byte buffer is too short");
    SEXP out = PROTECT(Rf_allocVector(STRSXP, n));
    static const char hex[] = "0123456789abcdef";
    const Rbyte *bytes = RAW(bytes_sexp);
    for (int i = 0; i < n; i++) {
        if (LOGICAL(valid_sexp)[i] != TRUE) {
            SET_STRING_ELT(out, i, NA_STRING);
            continue;
        }
        const Rbyte *src = bytes + (R_xlen_t)(offset + i) * 16;
        char buf[37];
        int pos = 0;
        for (int j = 0; j < 16; j++) {
            if (j == 4 || j == 6 || j == 8 || j == 10) buf[pos++] = '-';
            buf[pos++] = hex[(src[j] >> 4) & 0x0f];
            buf[pos++] = hex[src[j] & 0x0f];
        }
        buf[pos] = '\0';
        SET_STRING_ELT(out, i, Rf_mkCharLenCE(buf, 36, CE_UTF8));
    }
    UNPROTECT(1);
    return out;
}
