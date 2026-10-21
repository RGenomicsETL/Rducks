#ifndef R_NO_REMAP
#define R_NO_REMAP
#endif
#include <R.h>
#include <Rinternals.h>

#include <stdint.h>
#include <string.h>

/* Native fast paths for the NNG frame codec in R/ipc_nng_wire.R. The frame
 * layout is little endian:
 *
 *   request:  "RDK1" | u32 version | u32 type | u32 udf_len | u32 reserved |
 *             u64 row_count | u64 payload_len | udf_id bytes | payload bytes
 *   response: "RDK1" | u32 version | u32 100 | u32 status | u32 error_len |
 *             u32 0 | u64 payload_len | error bytes | payload bytes
 *
 * The request decoder accepts only a frame it fully understands and returns
 * NULL for anything else (bad magic, truncation, unknown type, dynamic-args
 * reserved flag, out-of-range counts, embedded NUL in the id). The R decoder
 * then runs and reports its usual error, so error text is unchanged. */

#define RDUCKS_WIRE_REQUEST_HEADER 36
#define RDUCKS_WIRE_RESPONSE_HEADER 32
#define RDUCKS_WIRE_VERSION 1u
#define RDUCKS_WIRE_TYPE_RESPONSE 100u

static uint32_t rducks_wire_rd_u32(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t rducks_wire_rd_u64(const unsigned char *p) {
    return (uint64_t)rducks_wire_rd_u32(p) | ((uint64_t)rducks_wire_rd_u32(p + 4) << 32);
}

static void rducks_wire_wr_u32(unsigned char *p, uint32_t v) {
    p[0] = (unsigned char)(v & 0xFFu);
    p[1] = (unsigned char)((v >> 8) & 0xFFu);
    p[2] = (unsigned char)((v >> 16) & 0xFFu);
    p[3] = (unsigned char)((v >> 24) & 0xFFu);
}

static void rducks_wire_wr_u64(unsigned char *p, uint64_t v) {
    rducks_wire_wr_u32(p, (uint32_t)(v & 0xFFFFFFFFu));
    rducks_wire_wr_u32(p + 4, (uint32_t)(v >> 32));
}

SEXP RDUCKS_nng_wire_decode_request_fast(SEXP buf) {
    const unsigned char *p;
    R_xlen_t len;
    uint32_t version, type, udf_len, reserved;
    uint64_t row_count, payload_len, total;
    SEXP out, names, payload;

    if (TYPEOF(buf) != RAWSXP) return R_NilValue;
    len = XLENGTH(buf);
    if (len < RDUCKS_WIRE_REQUEST_HEADER) return R_NilValue;
    p = RAW(buf);
    if (memcmp(p, "RDK1", 4) != 0) return R_NilValue;

    version = rducks_wire_rd_u32(p + 4);
    type = rducks_wire_rd_u32(p + 8);
    udf_len = rducks_wire_rd_u32(p + 12);
    reserved = rducks_wire_rd_u32(p + 16);
    row_count = rducks_wire_rd_u64(p + 20);
    payload_len = rducks_wire_rd_u64(p + 28);

    if (version != RDUCKS_WIRE_VERSION) return R_NilValue;
    if (type < 1u || type > 4u) return R_NilValue;
    if (reserved != 0u) return R_NilValue; /* dynamic-args payload: R path */
    if (row_count > (uint64_t)INT32_MAX) return R_NilValue;
    if (udf_len > (uint32_t)INT32_MAX) return R_NilValue;
    if (payload_len > (uint64_t)len) return R_NilValue;
    total = (uint64_t)RDUCKS_WIRE_REQUEST_HEADER + (uint64_t)udf_len + payload_len;
    if (total != (uint64_t)len) return R_NilValue;
    for (uint32_t i = 0; i < udf_len; i++) {
        if (p[RDUCKS_WIRE_REQUEST_HEADER + i] == 0) return R_NilValue; /* rawToChar would reject */
    }

    out = PROTECT(Rf_allocVector(VECSXP, 5));
    SET_VECTOR_ELT(out, 0, Rf_ScalarInteger((int)type));
    SET_VECTOR_ELT(out, 1, Rf_ScalarString(Rf_mkCharLen((const char *)p + RDUCKS_WIRE_REQUEST_HEADER, (int)udf_len)));
    SET_VECTOR_ELT(out, 2, Rf_ScalarInteger((int)row_count));
    payload = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)payload_len));
    if (payload_len > 0) {
        memcpy(RAW(payload), p + RDUCKS_WIRE_REQUEST_HEADER + udf_len, (size_t)payload_len);
    }
    SET_VECTOR_ELT(out, 3, payload);
    SET_VECTOR_ELT(out, 4, R_NilValue);

    names = PROTECT(Rf_allocVector(STRSXP, 5));
    SET_STRING_ELT(names, 0, Rf_mkChar("type"));
    SET_STRING_ELT(names, 1, Rf_mkChar("udf_id"));
    SET_STRING_ELT(names, 2, Rf_mkChar("row_count"));
    SET_STRING_ELT(names, 3, Rf_mkChar("payload"));
    SET_STRING_ELT(names, 4, Rf_mkChar("dynamic_arg_tokens"));
    Rf_setAttrib(out, R_NamesSymbol, names);
    UNPROTECT(3);
    return out;
}

SEXP RDUCKS_nng_wire_encode_response_fast(SEXP status_code, SEXP payload, SEXP error) {
    int code;
    const char *err;
    size_t err_len;
    R_xlen_t payload_len;
    uint64_t total;
    SEXP out;
    unsigned char *q;

    code = Rf_asInteger(status_code);
    if (code != 0 && code != 1) Rf_error("NNG wire response status must be 'ok' or 'error'");
    if (TYPEOF(payload) != RAWSXP) Rf_error("NNG wire payload must be raw");
    if (TYPEOF(error) != STRSXP || XLENGTH(error) != 1 || STRING_ELT(error, 0) == NA_STRING) {
        Rf_error("NNG wire response error must be a non-missing character scalar");
    }
    err = Rf_translateCharUTF8(STRING_ELT(error, 0));
    err_len = strlen(err);
    if (err_len > (size_t)UINT32_MAX) Rf_error("NNG wire response error is too long");
    payload_len = XLENGTH(payload);
    total = (uint64_t)RDUCKS_WIRE_RESPONSE_HEADER + (uint64_t)err_len + (uint64_t)payload_len;
    if (total > (uint64_t)R_XLEN_T_MAX) Rf_error("NNG wire response frame is too large");

    out = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)total));
    q = RAW(out);
    memcpy(q, "RDK1", 4);
    rducks_wire_wr_u32(q + 4, RDUCKS_WIRE_VERSION);
    rducks_wire_wr_u32(q + 8, RDUCKS_WIRE_TYPE_RESPONSE);
    rducks_wire_wr_u32(q + 12, (uint32_t)code);
    rducks_wire_wr_u32(q + 16, (uint32_t)err_len);
    rducks_wire_wr_u32(q + 20, 0u);
    rducks_wire_wr_u64(q + 24, (uint64_t)payload_len);
    if (err_len > 0) memcpy(q + RDUCKS_WIRE_RESPONSE_HEADER, err, err_len);
    if (payload_len > 0) memcpy(q + RDUCKS_WIRE_RESPONSE_HEADER + err_len, RAW(payload), (size_t)payload_len);
    UNPROTECT(1);
    return out;
}

/* TRUE for each list element that is NULL. Replaces vapply(x, is.null, ...) on
 * the per-chunk worker path. */
SEXP RDUCKS_list_is_null(SEXP x) {
    R_xlen_t n;
    SEXP out;
    if (TYPEOF(x) != VECSXP) Rf_error("expected a list");
    n = XLENGTH(x);
    out = PROTECT(Rf_allocVector(LGLSXP, n));
    for (R_xlen_t i = 0; i < n; i++) {
        LOGICAL(out)[i] = VECTOR_ELT(x, i) == R_NilValue;
    }
    UNPROTECT(1);
    return out;
}
