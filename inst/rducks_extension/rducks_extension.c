/* Rducks DuckDB extension
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#ifndef R_NO_REMAP
#define R_NO_REMAP
#endif
#include "duckdb_extension.h"

#include <R.h>
#include <Rinternals.h>
#include <R_ext/Arith.h>

#include <nanoarrow/r.h>

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

DUCKDB_EXTENSION_EXTERN


typedef enum rducks_type_id {
    RDUCKS_TYPE_INVALID = 0,
    RDUCKS_TYPE_BOOL,
    RDUCKS_TYPE_I8,
    RDUCKS_TYPE_U8,
    RDUCKS_TYPE_I16,
    RDUCKS_TYPE_U16,
    RDUCKS_TYPE_I32,
    RDUCKS_TYPE_U32,
    RDUCKS_TYPE_I64,
    RDUCKS_TYPE_U64,
    RDUCKS_TYPE_F32,
    RDUCKS_TYPE_F64,
    RDUCKS_TYPE_VARCHAR,
    RDUCKS_TYPE_BLOB,
    RDUCKS_TYPE_DATE,
    RDUCKS_TYPE_TIME,
    RDUCKS_TYPE_TIMESTAMP,
    RDUCKS_TYPE_HUGEINT,
    RDUCKS_TYPE_UHUGEINT,
    RDUCKS_TYPE_UUID,
    RDUCKS_TYPE_INTERVAL,
    RDUCKS_TYPE_BIT
} rducks_type_id_t;

typedef enum rducks_null_handling {
    RDUCKS_NULL_DEFAULT = 0,
    RDUCKS_NULL_SPECIAL = 1
} rducks_null_handling_t;

typedef enum rducks_exception_handling {
    RDUCKS_EXCEPTION_RETHROW = 0,
    RDUCKS_EXCEPTION_RETURN_NULL = 1
} rducks_exception_handling_t;

typedef enum rducks_eval_mode {
    RDUCKS_EVAL_R = 0,
    RDUCKS_EVAL_RC = 1
} rducks_eval_mode_t;

typedef enum rducks_type_kind {
    RDUCKS_KIND_SCALAR = 0,
    RDUCKS_KIND_LIST,
    RDUCKS_KIND_ARRAY,
    RDUCKS_KIND_STRUCT,
    RDUCKS_KIND_MAP,
    RDUCKS_KIND_DECIMAL,
    RDUCKS_KIND_ENUM,
    RDUCKS_KIND_UNION
} rducks_type_kind_t;

typedef struct rducks_type_desc {
    rducks_type_kind_t kind;
    rducks_type_id_t scalar;
    struct rducks_type_desc *child;
    struct rducks_type_desc *key;
    struct rducks_type_desc *value;
    idx_t array_size;
    uint8_t decimal_width;
    uint8_t decimal_scale;
    size_t field_count;
    char **field_names;
    struct rducks_type_desc **field_types;
} rducks_type_desc_t;

typedef struct rducks_r_scalar_meta {
    SEXP fun;
    size_t arity;
    struct rducks_type_desc **args;
    struct rducks_type_desc *return_desc;
    rducks_null_handling_t null_handling;
    rducks_exception_handling_t exception_handling;
    rducks_eval_mode_t eval_mode;
} rducks_r_scalar_meta_t;

static duckdb_database g_database = NULL;
static duckdb_connection g_connection = NULL;
static int g_registration_surface_ready = 0;
static char g_main_thread_token[128];
static int g_main_thread_token_set = 0;
static int rducks_rc_scalar_execute(rducks_r_scalar_meta_t *meta, duckdb_data_chunk input, duckdb_vector output,
                                    char *err_msg, size_t err_cap);
/* Implementation modules are included into one translation unit because
 * DuckDB loads a single extension shared object built by configure.
 */
#include "src/rducks_threads.c"
#include "src/rducks_util.c"
#include "src/rducks_types.c"
#include "src/rducks_runtime.c"
#include "src/rducks_arrow.c"
#include "src/rducks_rc.c"
#include "src/rducks_udf_sql.c"
#include "src/rducks_surfaces.c"
