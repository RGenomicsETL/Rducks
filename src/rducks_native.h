#ifndef RDUCKS_NATIVE_H
#define RDUCKS_NATIVE_H

#ifndef R_NO_REMAP
#define R_NO_REMAP
#endif
#include <R.h>
#include <Rinternals.h>

#include <stdint.h>
#include <string.h>

static inline R_xlen_t
rducks_xlen_mul(R_xlen_t a, R_xlen_t b, const char *what)
{
    if (a < 0 || b < 0 || (b != 0 && a > R_XLEN_T_MAX / b)) {
        Rf_error("%s length exceeds R vector size limit", what);
    }
    return a * b;
}

static inline R_xlen_t
rducks_xlen_add(R_xlen_t a, R_xlen_t b, const char *what)
{
    if (a < 0 || b < 0 || a > R_XLEN_T_MAX - b) {
        Rf_error("%s length exceeds R vector size limit", what);
    }
    return a + b;
}

static inline R_xlen_t
rducks_raw_span_len(R_xlen_t offset, R_xlen_t n, R_xlen_t width,
                    const char *what)
{
    return rducks_xlen_mul(rducks_xlen_add(offset, n, what), width, what);
}

static inline void
rducks_require_raw_span(SEXP bytes, R_xlen_t offset, R_xlen_t n,
                        R_xlen_t width, const char *what)
{
    if (XLENGTH(bytes) < rducks_raw_span_len(offset, n, width, what)) {
        Rf_error("%s buffer is too short", what);
    }
}

static inline R_xlen_t
rducks_bytes_for_bits(R_xlen_t bits, const char *what)
{
    if (bits < 0 || bits > R_XLEN_T_MAX - 7) {
        Rf_error("%s bit length exceeds R vector size limit", what);
    }
    return bits == 0 ? 0 : (bits + 7) / 8;
}

static inline void
rducks_require_bit_span(SEXP bytes, R_xlen_t offset, R_xlen_t n,
                        const char *what)
{
    R_xlen_t end_bit = rducks_xlen_add(offset, n, what);
    R_xlen_t need = rducks_bytes_for_bits(end_bit, what);
    if (XLENGTH(bytes) < need) {
        Rf_error("%s buffer is too short", what);
    }
}

static inline void
rducks_require_len(SEXP x, R_xlen_t n, const char *what)
{
    if (XLENGTH(x) < n) {
        Rf_error("%s is too short", what);
    }
}

static inline uint32_t
rducks_load_u32_le(const Rbyte *src)
{
    return ((uint32_t)src[0]) |
           ((uint32_t)src[1] << 8) |
           ((uint32_t)src[2] << 16) |
           ((uint32_t)src[3] << 24);
}

static inline uint64_t
rducks_load_u64_le(const Rbyte *src)
{
    uint64_t u = 0;
    for (int i = 7; i >= 0; i--) {
        u = (u << 8) | (uint64_t)src[i];
    }
    return u;
}

static inline void
rducks_store_u32_le(Rbyte *dst, uint32_t u)
{
    for (int i = 0; i < 4; i++) {
        dst[i] = (Rbyte)((u >> (8 * i)) & 0xffU);
    }
}

static inline void
rducks_store_u64_le(Rbyte *dst, uint64_t u)
{
    for (int i = 0; i < 8; i++) {
        dst[i] = (Rbyte)((u >> (8 * i)) & 0xffU);
    }
}

#endif
