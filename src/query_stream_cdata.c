#ifndef R_NO_REMAP
#define R_NO_REMAP
#endif
#include <R.h>
#include <Rinternals.h>

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <nanoarrow/r.h>

#define RDUCKS_QUERY_STREAM_CDATA_PREFIX "rducks-cdata:"

static uintptr_t rducks_parse_cdata_address(const char *text, const char **end_out) {
    char *end = NULL;
    unsigned long long value;
    if (!text || !text[0]) {
        Rf_error("invalid Rducks query stream Arrow C Data handle");
    }
    errno = 0;
    value = strtoull(text, &end, 16);
    if (errno != 0 || end == text || value == 0ULL || (uintptr_t)value != value) {
        Rf_error("invalid Rducks query stream Arrow C Data address");
    }
    if (end_out) *end_out = end;
    return (uintptr_t)value;
}

static SEXP rducks_arrow_schema_xptr(struct ArrowSchema *schema) {
    SEXP xptr = PROTECT(R_MakeExternalPtr(schema, R_NilValue, R_NilValue));
    SEXP cls = PROTECT(Rf_mkString("nanoarrow_schema"));
    Rf_setAttrib(xptr, R_ClassSymbol, cls);
    R_RegisterCFinalizer(xptr, &nanoarrow_finalize_schema_xptr);
    UNPROTECT(2);
    return xptr;
}

static SEXP rducks_arrow_array_xptr(struct ArrowArray *array, SEXP schema_xptr) {
    SEXP xptr = PROTECT(R_MakeExternalPtr(array, schema_xptr, R_NilValue));
    SEXP cls = PROTECT(Rf_mkString("nanoarrow_array"));
    Rf_setAttrib(xptr, R_ClassSymbol, cls);
    R_RegisterCFinalizer(xptr, &nanoarrow_finalize_array_xptr);
    UNPROTECT(2);
    return xptr;
}

SEXP RDUCKS_query_stream_wrap_cdata(SEXP handle_sexp) {
    const char *handle;
    const char *cursor;
    const char *prefix = RDUCKS_QUERY_STREAM_CDATA_PREFIX;
    size_t prefix_len = strlen(prefix);
    uintptr_t schema_addr;
    uintptr_t array_addr;
    struct ArrowSchema *schema;
    struct ArrowArray *array;
    SEXP schema_xptr;
    SEXP array_xptr;
    SEXP out;
    SEXP names;

    if (TYPEOF(handle_sexp) != STRSXP || XLENGTH(handle_sexp) != 1 || STRING_ELT(handle_sexp, 0) == NA_STRING) {
        Rf_error("handle must be a non-missing character scalar");
    }
    handle = CHAR(STRING_ELT(handle_sexp, 0));
    if (strncmp(handle, prefix, prefix_len) != 0) {
        Rf_error("invalid Rducks query stream Arrow C Data handle");
    }

    cursor = handle + prefix_len;
    schema_addr = rducks_parse_cdata_address(cursor, &cursor);
    if (*cursor != ':') {
        Rf_error("invalid Rducks query stream Arrow C Data handle separator");
    }
    cursor++;
    array_addr = rducks_parse_cdata_address(cursor, &cursor);
    if (*cursor != '\0') {
        Rf_error("invalid Rducks query stream Arrow C Data handle trailer");
    }

    schema = (struct ArrowSchema *)schema_addr;
    array = (struct ArrowArray *)array_addr;
    if (!schema->release || !array->release) {
        Rf_error("Rducks query stream Arrow C Data handle is not initialized");
    }

    schema_xptr = PROTECT(rducks_arrow_schema_xptr(schema));
    array_xptr = PROTECT(rducks_arrow_array_xptr(array, schema_xptr));
    out = PROTECT(Rf_allocVector(VECSXP, 2));
    names = PROTECT(Rf_allocVector(STRSXP, 2));
    SET_VECTOR_ELT(out, 0, array_xptr);
    SET_VECTOR_ELT(out, 1, schema_xptr);
    SET_STRING_ELT(names, 0, Rf_mkChar("array"));
    SET_STRING_ELT(names, 1, Rf_mkChar("schema"));
    Rf_setAttrib(out, R_NamesSymbol, names);
    UNPROTECT(4);
    return out;
}
