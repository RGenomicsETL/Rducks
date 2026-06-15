#ifndef R_NO_REMAP
#define R_NO_REMAP
#endif
#include <R.h>
#include <Rinternals.h>

#include "rducks_native.h"

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static void rducks_interval_write_i32_le(Rbyte *dst, int32_t value) {
    uint32_t u;
    memcpy(&u, &value, sizeof(u));
    rducks_store_u32_le(dst, u);
}

static void rducks_interval_write_i64_le(Rbyte *dst, int64_t value) {
    uint64_t u;
    memcpy(&u, &value, sizeof(u));
    rducks_store_u64_le(dst, u);
}

static int rducks_interval_parse_i64(SEXP x, int64_t *out) {
    if (TYPEOF(x) != STRSXP || XLENGTH(x) < 1 || STRING_ELT(x, 0) == NA_STRING) return 0;
    const char *s = CHAR(STRING_ELT(x, 0));
    char *end = NULL;
    errno = 0;
    long long value = strtoll(s, &end, 10);
    if (errno == ERANGE || end == s) return 0;
    while (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r' || *end == '\f' || *end == '\v') end++;
    if (*end != '\0') return 0;
    *out = (int64_t)value;
    return 1;
}

static SEXP rducks_interval_named2(SEXP valid, SEXP data) {
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 2));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 2));
    SET_VECTOR_ELT(out, 0, valid);
    SET_VECTOR_ELT(out, 1, data);
    SET_STRING_ELT(names, 0, Rf_mkChar("valid"));
    SET_STRING_ELT(names, 1, Rf_mkChar("data"));
    Rf_setAttrib(out, R_NamesSymbol, names);
    UNPROTECT(2);
    return out;
}

SEXP RDUCKS_interval_bytes_from_values(SEXP values) {
    if (TYPEOF(values) != VECSXP) Rf_error("values must be a list");
    R_xlen_t n = XLENGTH(values);
    R_xlen_t data_len = rducks_xlen_mul(n, 16, "INTERVAL byte");
    SEXP valid = PROTECT(Rf_allocVector(LGLSXP, n));
    SEXP data = PROTECT(Rf_allocVector(RAWSXP, data_len));
    memset(RAW(data), 0, (size_t)data_len);
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP value = VECTOR_ELT(values, i);
        if (value == R_NilValue) {
            LOGICAL(valid)[i] = FALSE;
            continue;
        }
        if (TYPEOF(value) != VECSXP || XLENGTH(value) < 3) Rf_error("INTERVAL values must be rducks_interval objects");
        SEXP months = VECTOR_ELT(value, 0);
        SEXP days = VECTOR_ELT(value, 1);
        SEXP micros = VECTOR_ELT(value, 2);
        int month = Rf_asInteger(months);
        int day = Rf_asInteger(days);
        int64_t micro = 0;
        if (month == NA_INTEGER || day == NA_INTEGER || !rducks_interval_parse_i64(micros, &micro)) {
            LOGICAL(valid)[i] = FALSE;
            continue;
        }
        if (micro > INT64_MAX / 1000LL || micro < INT64_MIN / 1000LL) {
            Rf_error("INTERVAL microseconds do not fit in nanosecond storage");
        }
        LOGICAL(valid)[i] = TRUE;
        Rbyte *dst = RAW(data) + i * 16;
        rducks_interval_write_i32_le(dst, (int32_t)month);
        rducks_interval_write_i32_le(dst + 4, (int32_t)day);
        rducks_interval_write_i64_le(dst + 8, micro * 1000LL);
    }
    SEXP out = PROTECT(rducks_interval_named2(valid, data));
    UNPROTECT(3);
    return out;
}
