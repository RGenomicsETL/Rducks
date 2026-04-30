#ifndef R_NO_REMAP
#define R_NO_REMAP
#endif
#include <R.h>
#include <Rinternals.h>
#include <string.h>

static int rducks_is_string_scalar(SEXP x) {
    return TYPEOF(x) == STRSXP && XLENGTH(x) == 1 && STRING_ELT(x, 0) != NA_STRING &&
           strlen(CHAR(STRING_ELT(x, 0))) > 0;
}

static int rducks_class_contains(SEXP klass, const char *name) {
    if (TYPEOF(klass) != STRSXP) {
        return 0;
    }
    R_xlen_t n = XLENGTH(klass);
    for (R_xlen_t i = 0; i < n; ++i) {
        if (STRING_ELT(klass, i) != NA_STRING && strcmp(CHAR(STRING_ELT(klass, i)), name) == 0) {
            return 1;
        }
    }
    return 0;
}

static int rducks_string_at_equals(SEXP x, R_xlen_t i, const char *value) {
    return TYPEOF(x) == STRSXP && i >= 0 && i < XLENGTH(x) &&
           STRING_ELT(x, i) != NA_STRING && strcmp(CHAR(STRING_ELT(x, i)), value) == 0;
}

static int rducks_string_at_nonempty(SEXP x, R_xlen_t i) {
    return TYPEOF(x) == STRSXP && i >= 0 && i < XLENGTH(x) &&
           STRING_ELT(x, i) != NA_STRING && strlen(CHAR(STRING_ELT(x, i))) > 0;
}

static SEXP rducks_list_get(SEXP list, const char *name) {
    SEXP names = Rf_getAttrib(list, R_NamesSymbol);
    if (TYPEOF(list) != VECSXP || TYPEOF(names) != STRSXP) {
        return R_NilValue;
    }
    for (R_xlen_t i = 0; i < XLENGTH(list); ++i) {
        if (STRING_ELT(names, i) != NA_STRING && strcmp(CHAR(STRING_ELT(names, i)), name) == 0) {
            return VECTOR_ELT(list, i);
        }
    }
    return R_NilValue;
}

static int rducks_string_vector_unique_nonempty(SEXP x) {
    if (TYPEOF(x) != STRSXP || XLENGTH(x) == 0) {
        return 0;
    }
    for (R_xlen_t i = 0; i < XLENGTH(x); ++i) {
        if (!rducks_string_at_nonempty(x, i)) return 0;
        for (R_xlen_t j = 0; j < i; ++j) {
            if (strcmp(CHAR(STRING_ELT(x, i)), CHAR(STRING_ELT(x, j))) == 0) return 0;
        }
    }
    return 1;
}

static int rducks_int_scalar_between(SEXP x, int lo, int hi) {
    if (TYPEOF(x) != INTSXP || XLENGTH(x) != 1) return 0;
    int value = INTEGER(x)[0];
    return value != NA_INTEGER && value >= lo && value <= hi;
}

static int rducks_type_object_is_rec(SEXP x, int depth) {
    if (depth > 64) {
        return 0;
    }
    if (TYPEOF(x) != VECSXP) {
        return 0;
    }
    SEXP klass = Rf_getAttrib(x, R_ClassSymbol);
    if (!rducks_class_contains(klass, "rducks_type") || !rducks_class_contains(klass, "S7_object")) {
        return 0;
    }
    if (Rf_getAttrib(x, Rf_install("S7_class")) == R_NilValue) {
        return 0;
    }

    SEXP token = Rf_getAttrib(x, Rf_install("token"));
    SEXP duckdb_sql = Rf_getAttrib(x, Rf_install("duckdb_sql"));
    SEXP kind = Rf_getAttrib(x, Rf_install("kind"));
    SEXP children = Rf_getAttrib(x, Rf_install("children"));
    SEXP child_names = Rf_getAttrib(x, Rf_install("child_names"));
    SEXP size = Rf_getAttrib(x, Rf_install("size"));
    SEXP parameters = Rf_getAttrib(x, Rf_install("parameters"));

    if (!rducks_is_string_scalar(token) || !rducks_is_string_scalar(duckdb_sql) || !rducks_is_string_scalar(kind)) {
        return 0;
    }
    if (TYPEOF(children) != VECSXP || TYPEOF(child_names) != STRSXP || TYPEOF(size) != INTSXP || XLENGTH(size) != 1 ||
        TYPEOF(parameters) != VECSXP) {
        return 0;
    }
    if (XLENGTH(children) != XLENGTH(child_names)) {
        return 0;
    }
    const char *kind_chr = CHAR(STRING_ELT(kind, 0));
    R_xlen_t n_children = XLENGTH(children);
    int size_value = INTEGER(size)[0];
    if (strcmp(kind_chr, "scalar") == 0) {
        if (n_children != 0) return 0;
    } else if (strcmp(kind_chr, "decimal") == 0) {
        SEXP width = rducks_list_get(parameters, "width");
        SEXP scale = rducks_list_get(parameters, "scale");
        if (n_children != 0 || size_value != NA_INTEGER || !rducks_int_scalar_between(width, 1, 38) ||
            !rducks_int_scalar_between(scale, 0, INTEGER(width)[0])) return 0;
    } else if (strcmp(kind_chr, "enum") == 0) {
        SEXP levels = rducks_list_get(parameters, "levels");
        if (n_children != 0 || size_value != NA_INTEGER || !rducks_string_vector_unique_nonempty(levels)) return 0;
    } else if (strcmp(kind_chr, "list") == 0) {
        if (n_children != 1 || !rducks_string_at_equals(child_names, 0, "child") || size_value != NA_INTEGER) return 0;
    } else if (strcmp(kind_chr, "array") == 0) {
        if (n_children != 1 || !rducks_string_at_equals(child_names, 0, "child") || size_value == NA_INTEGER || size_value <= 0) return 0;
    } else if (strcmp(kind_chr, "struct") == 0) {
        if (n_children == 0 || size_value != NA_INTEGER) return 0;
        for (R_xlen_t i = 0; i < n_children; ++i) {
            if (!rducks_string_at_nonempty(child_names, i)) return 0;
        }
    } else if (strcmp(kind_chr, "map") == 0) {
        if (n_children != 2 || !rducks_string_at_equals(child_names, 0, "key") ||
            !rducks_string_at_equals(child_names, 1, "value") || size_value != NA_INTEGER) return 0;
    } else if (strcmp(kind_chr, "union") == 0) {
        if (n_children == 0 || size_value != NA_INTEGER) return 0;
        for (R_xlen_t i = 0; i < n_children; ++i) {
            if (!rducks_string_at_nonempty(child_names, i)) return 0;
        }
    } else {
        return 0;
    }

    for (R_xlen_t i = 0; i < n_children; ++i) {
        if (!rducks_type_object_is_rec(VECTOR_ELT(children, i), depth + 1)) {
            return 0;
        }
    }
    return 1;
}

SEXP RDUCKS_type_object_new(SEXP token, SEXP duckdb_sql, SEXP kind, SEXP children,
                            SEXP child_names, SEXP size, SEXP parameters,
                            SEXP s7_class, SEXP class_vector) {
    if (!rducks_is_string_scalar(token)) {
        Rf_error("token must be a non-empty character scalar");
    }
    if (!rducks_is_string_scalar(duckdb_sql)) {
        Rf_error("duckdb_sql must be a non-empty character scalar");
    }
    if (!rducks_is_string_scalar(kind)) {
        Rf_error("kind must be a non-empty character scalar");
    }
    if (TYPEOF(children) != VECSXP) {
        Rf_error("children must be a list");
    }
    if (TYPEOF(child_names) != STRSXP || XLENGTH(child_names) != XLENGTH(children)) {
        Rf_error("child_names must be a character vector matching children");
    }
    if (TYPEOF(size) != INTSXP || XLENGTH(size) != 1) {
        Rf_error("size must be an integer scalar");
    }
    if (TYPEOF(parameters) != VECSXP) {
        Rf_error("parameters must be a list");
    }
    if (s7_class == R_NilValue) {
        Rf_error("s7_class must not be NULL");
    }
    if (TYPEOF(class_vector) != STRSXP || XLENGTH(class_vector) < 3) {
        Rf_error("class_vector must be a character vector");
    }

    SEXP out = PROTECT(Rf_allocVector(VECSXP, 7));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 7));
    SET_STRING_ELT(names, 0, Rf_mkChar("token"));
    SET_STRING_ELT(names, 1, Rf_mkChar("duckdb_sql"));
    SET_STRING_ELT(names, 2, Rf_mkChar("kind"));
    SET_STRING_ELT(names, 3, Rf_mkChar("children"));
    SET_STRING_ELT(names, 4, Rf_mkChar("child_names"));
    SET_STRING_ELT(names, 5, Rf_mkChar("size"));
    SET_STRING_ELT(names, 6, Rf_mkChar("parameters"));

    SET_VECTOR_ELT(out, 0, token);
    SET_VECTOR_ELT(out, 1, duckdb_sql);
    SET_VECTOR_ELT(out, 2, kind);
    SET_VECTOR_ELT(out, 3, children);
    SET_VECTOR_ELT(out, 4, child_names);
    SET_VECTOR_ELT(out, 5, size);
    SET_VECTOR_ELT(out, 6, parameters);

    Rf_setAttrib(out, R_NamesSymbol, names);
    Rf_setAttrib(out, R_ClassSymbol, class_vector);
    Rf_setAttrib(out, Rf_install("S7_class"), s7_class);
    Rf_setAttrib(out, Rf_install("token"), token);
    Rf_setAttrib(out, Rf_install("duckdb_sql"), duckdb_sql);
    Rf_setAttrib(out, Rf_install("kind"), kind);
    Rf_setAttrib(out, Rf_install("children"), children);
    Rf_setAttrib(out, Rf_install("child_names"), child_names);
    Rf_setAttrib(out, Rf_install("size"), size);
    Rf_setAttrib(out, Rf_install("parameters"), parameters);

    UNPROTECT(2);
    return out;
}

SEXP RDUCKS_type_object_is(SEXP x) {
    return Rf_ScalarLogical(rducks_type_object_is_rec(x, 0));
}
