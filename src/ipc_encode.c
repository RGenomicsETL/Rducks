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

/* Compile the vendored nanoarrow C/IPC implementation into the R package
 * shared library too. This is deliberately not a dlopen/dlsym path into the
 * nanoarrow R package shared object.
 */
#include "../inst/rducks_extension/src/rducks_vendor_nanoarrow.c"
#include "../inst/rducks_extension/src/rducks_vendor_ipc_helpers.h"

typedef struct rducks_ipc_encode_result {
    uint8_t *bytes;
    size_t size;
} rducks_ipc_encode_result_t;

static void rducks_ipc_encode_result_cleanup(void *data, Rboolean jump) {
    (void)jump;
    rducks_ipc_encode_result_t *result = (rducks_ipc_encode_result_t *)data;
    if (result && result->bytes) {
        free(result->bytes);
        result->bytes = NULL;
        result->size = 0;
    }
}

static SEXP rducks_ipc_encode_result_to_raw(void *data) {
    rducks_ipc_encode_result_t *result = (rducks_ipc_encode_result_t *)data;
    if (!result || result->size > (size_t)R_XLEN_T_MAX) {
        Rf_error("Arrow IPC payload is too large for an R raw vector");
    }
    SEXP out = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)result->size));
    if (result->size > 0) memcpy(RAW(out), result->bytes, result->size);
    UNPROTECT(1);
    return out;
}

SEXP RDUCKS_arrow_ipc_encode_array(SEXP array_xptr) {
    SEXP schema_xptr = R_NilValue;
    struct ArrowArray *array;
    struct ArrowSchema *schema;
    char err[512];
    rducks_ipc_encode_result_t result;

    memset(&result, 0, sizeof(result));
    err[0] = '\0';

    if (!Rf_inherits(array_xptr, "nanoarrow_array")) {
        Rf_error("array_xptr must be a nanoarrow_array external pointer");
    }
    schema_xptr = R_ExternalPtrTag(array_xptr);
    if (schema_xptr == R_NilValue || !Rf_inherits(schema_xptr, "nanoarrow_schema")) {
        Rf_error("nanoarrow_array does not carry a nanoarrow_schema tag");
    }
    array = nanoarrow_array_from_xptr(array_xptr);
    schema = nanoarrow_schema_from_xptr(schema_xptr);

    if (!rducks_arrow_ipc_encode_borrowed_array(schema, array, &result.bytes, &result.size, err, sizeof(err))) {
        Rf_error("Arrow IPC encoding failed: %s", err[0] ? err : "unknown error");
    }

    return R_UnwindProtect(rducks_ipc_encode_result_to_raw, &result,
                           rducks_ipc_encode_result_cleanup, &result,
                           NULL);
}
