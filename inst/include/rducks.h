#ifndef RDUCKS_H
#define RDUCKS_H

#include <Rinternals.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum rducks_arg_kind {
    RDUCKS_ARG_BOOL = 1,
    RDUCKS_ARG_I32 = 2,
    RDUCKS_ARG_I64 = 3,
    RDUCKS_ARG_F32 = 4,
    RDUCKS_ARG_F64 = 5,
    RDUCKS_ARG_VARCHAR = 6,
    RDUCKS_ARG_SEXP = 7
} rducks_arg_kind_t;

typedef struct rducks_arg {
    rducks_arg_kind_t kind;
    union {
        int logical;
        int32_t i32;
        int64_t i64;
        float f32;
        double f64;
        const char *varchar;
        SEXP sexp;
    } value;
} rducks_arg_t;

typedef struct rducks_result {
    rducks_arg_kind_t kind;
    int is_null;
    union {
        int logical;
        int32_t i32;
        int64_t i64;
        float f32;
        double f64;
        const char *varchar;
        SEXP sexp;
    } value;
} rducks_result_t;

#ifdef __cplusplus
}
#endif

#endif
