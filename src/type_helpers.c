#ifndef R_NO_REMAP
#define R_NO_REMAP
#endif
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Arith.h>

#include <math.h>
#include <string.h>

static int rducks_streq(const char *a, const char *b) {
    return a && b && strcmp(a, b) == 0;
}

static int rducks_class_matches_name(const char *klass, const char *name) {
    const char *suffix;
    if (!klass || !name || !name[0]) return 0;
    if (strcmp(klass, name) == 0) return 1;
    suffix = strstr(klass, "::");
    if (suffix && strcmp(suffix + 2, name) == 0) return 1;
    if (strncmp(name, "Rducks::", 8) != 0) {
        return strncmp(klass, "Rducks::", 8) == 0 && strcmp(klass + 8, name) == 0;
    }
    return 0;
}

static int rducks_inherits_name(SEXP x, const char *name) {
    SEXP klass = Rf_getAttrib(x, R_ClassSymbol);
    R_xlen_t n;
    if (TYPEOF(klass) != STRSXP) return 0;
    n = XLENGTH(klass);
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP elt = STRING_ELT(klass, i);
        if (elt != NA_STRING && rducks_class_matches_name(CHAR(elt), name)) return 1;
    }
    return 0;
}

SEXP RDUCKS_type_inherits_names(SEXP x, SEXP names) {
    if (TYPEOF(names) != STRSXP) {
        Rf_error("type inheritance names must be a character vector");
    }
    for (R_xlen_t i = 0; i < XLENGTH(names); i++) {
        SEXP elt = STRING_ELT(names, i);
        if (elt != NA_STRING && rducks_inherits_name(x, CHAR(elt))) {
            return Rf_ScalarLogical(1);
        }
    }
    return Rf_ScalarLogical(0);
}

static SEXP rducks_get_named_elt(SEXP x, const char *name) {
    SEXP names;
    if (TYPEOF(x) != VECSXP) return R_NilValue;
    names = Rf_getAttrib(x, R_NamesSymbol);
    if (TYPEOF(names) != STRSXP) return R_NilValue;
    for (R_xlen_t i = 0; i < XLENGTH(x) && i < XLENGTH(names); i++) {
        SEXP nm = STRING_ELT(names, i);
        if (nm != NA_STRING && strcmp(CHAR(nm), name) == 0) {
            return VECTOR_ELT(x, i);
        }
    }
    return R_NilValue;
}

static const char *rducks_type_scalar_token(SEXP type) {
    SEXP kind = rducks_get_named_elt(type, "kind");
    SEXP token = rducks_get_named_elt(type, "token");
    if (TYPEOF(kind) != STRSXP || XLENGTH(kind) < 1 || STRING_ELT(kind, 0) == NA_STRING) return NULL;
    if (!rducks_streq(CHAR(STRING_ELT(kind, 0)), "scalar")) return NULL;
    if (TYPEOF(token) != STRSXP || XLENGTH(token) < 1 || STRING_ELT(token, 0) == NA_STRING) return NULL;
    return CHAR(STRING_ELT(token, 0));
}

static int rducks_token_is_fast_scalar(const char *token) {
    if (!token) return 0;
    return rducks_streq(token, "bool") || rducks_streq(token, "i8") ||
           rducks_streq(token, "u8") || rducks_streq(token, "i16") ||
           rducks_streq(token, "u16") || rducks_streq(token, "i32") ||
           rducks_streq(token, "u32") || rducks_streq(token, "f32") ||
           rducks_streq(token, "f64") || rducks_streq(token, "varchar") ||
           rducks_streq(token, "date") || rducks_streq(token, "time") ||
           rducks_streq(token, "timestamp");
}

static int rducks_value_is_numeric(SEXP value) {
    return TYPEOF(value) == INTSXP || TYPEOF(value) == REALSXP;
}

static double rducks_numeric_at(SEXP value, R_xlen_t i) {
    if (TYPEOF(value) == INTSXP) {
        int v = INTEGER(value)[i];
        return v == NA_INTEGER ? NA_REAL : (double)v;
    }
    return REAL(value)[i];
}

static void rducks_check_integer_range(SEXP value, const char *sql, double lo, double hi) {
    if (!rducks_value_is_numeric(value)) {
        Rf_error("return value is not compatible with %s", sql);
    }
    for (R_xlen_t i = 0; i < XLENGTH(value); i++) {
        double v = rducks_numeric_at(value, i);
        if (R_IsNA(v)) continue;
        if (R_IsNaN(v) || !R_FINITE(v) || v != trunc(v) || v < lo || v > hi) {
            Rf_error("return value must contain finite whole-number values in range for %s", sql);
        }
    }
}

static void rducks_check_date(SEXP value) {
    if (!rducks_value_is_numeric(value)) {
        Rf_error("return value is not compatible with DATE");
    }
    for (R_xlen_t i = 0; i < XLENGTH(value); i++) {
        double v = rducks_numeric_at(value, i);
        if (R_IsNA(v)) continue;
        if (R_IsNaN(v) || !R_FINITE(v) || v != trunc(v) || v < -2147483648.0 || v > 2147483647.0) {
            Rf_error("return value must contain finite whole-day values in range for DATE");
        }
    }
}

static void rducks_check_time(SEXP value) {
    if (!rducks_value_is_numeric(value)) {
        Rf_error("return value is not compatible with TIME");
    }
    for (R_xlen_t i = 0; i < XLENGTH(value); i++) {
        double v = rducks_numeric_at(value, i);
        double rounded;
        if (R_IsNA(v)) continue;
        rounded = round(v * 1000000.0);
        if (R_IsNaN(v) || !R_FINITE(v) || v < 0.0 || v >= 86400.0 ||
            rounded < 0.0 || rounded >= 86400000000.0) {
            Rf_error("return value must contain finite seconds in [0, 86400) for TIME");
        }
    }
}

static void rducks_check_timestamp(SEXP value) {
    if (!rducks_value_is_numeric(value)) {
        Rf_error("return value is not compatible with TIMESTAMP");
    }
    for (R_xlen_t i = 0; i < XLENGTH(value); i++) {
        double v = rducks_numeric_at(value, i);
        if (R_IsNA(v)) continue;
        if (R_IsNaN(v) || !R_FINITE(v) || v < -9223372036854.774 || v > 9223372036854.774) {
            Rf_error("return value must contain finite POSIXct-compatible seconds for TIMESTAMP");
        }
    }
}

static void rducks_validate_fast_scalar_value(const char *token, SEXP value) {
    if (rducks_streq(token, "bool")) {
        if (TYPEOF(value) != LGLSXP) Rf_error("return value is not compatible with BOOLEAN");
    } else if (rducks_streq(token, "i8")) {
        rducks_check_integer_range(value, "TINYINT", -128.0, 127.0);
    } else if (rducks_streq(token, "u8")) {
        rducks_check_integer_range(value, "UTINYINT", 0.0, 255.0);
    } else if (rducks_streq(token, "i16")) {
        rducks_check_integer_range(value, "SMALLINT", -32768.0, 32767.0);
    } else if (rducks_streq(token, "u16")) {
        rducks_check_integer_range(value, "USMALLINT", 0.0, 65535.0);
    } else if (rducks_streq(token, "i32")) {
        rducks_check_integer_range(value, "INTEGER", -2147483648.0, 2147483647.0);
    } else if (rducks_streq(token, "u32")) {
        rducks_check_integer_range(value, "UINTEGER", 0.0, 4294967295.0);
    } else if (rducks_streq(token, "f32")) {
        if (!rducks_value_is_numeric(value)) Rf_error("return value is not compatible with FLOAT");
    } else if (rducks_streq(token, "f64")) {
        if (!rducks_value_is_numeric(value)) Rf_error("return value is not compatible with DOUBLE");
    } else if (rducks_streq(token, "varchar")) {
        if (TYPEOF(value) != STRSXP) Rf_error("return value is not compatible with VARCHAR");
    } else if (rducks_streq(token, "date")) {
        rducks_check_date(value);
    } else if (rducks_streq(token, "time")) {
        rducks_check_time(value);
    } else if (rducks_streq(token, "timestamp")) {
        rducks_check_timestamp(value);
    }
}

SEXP RDUCKS_vectorized_fast_scalar_rows(SEXP type, SEXP value, SEXP n_sexp) {
    const char *token = rducks_type_scalar_token(type);
    R_xlen_t n;
    SEXP out;
    if (!rducks_token_is_fast_scalar(token)) return R_NilValue;
    if (TYPEOF(value) == VECSXP) return R_NilValue;
    n = (R_xlen_t)Rf_asInteger(n_sexp);
    if (n < 0) Rf_error("vectorized return length is invalid");
    if (XLENGTH(value) != n) {
        Rf_error("vectorized return value must have length %lld, got %lld",
                 (long long)n, (long long)XLENGTH(value));
    }
    rducks_validate_fast_scalar_value(token, value);
    out = PROTECT(Rf_coerceVector(value, VECSXP));
    UNPROTECT(1);
    return out;
}
