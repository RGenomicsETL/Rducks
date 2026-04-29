/* Rducks DuckDB extension
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "duckdb_extension.h"

#include <R.h>
#include <Rinternals.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

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
    RDUCKS_TYPE_TIMESTAMP
} rducks_type_id_t;

typedef struct rducks_blob {
    const uint8_t *ptr;
    uint64_t len;
} rducks_blob_t;

typedef bool (*rducks_scalar_wrapper_fn_t)(SEXP fun, void **args, const bool *arg_is_null, void *out_value,
                                           bool *out_is_null);

typedef enum rducks_null_handling {
    RDUCKS_NULL_DEFAULT = 0,
    RDUCKS_NULL_SPECIAL = 1
} rducks_null_handling_t;

typedef enum rducks_exception_handling {
    RDUCKS_EXCEPTION_RETHROW = 0,
    RDUCKS_EXCEPTION_RETURN_NULL = 1
} rducks_exception_handling_t;

typedef struct rducks_r_scalar_meta {
    SEXP fun;
    rducks_scalar_wrapper_fn_t wrapper;
    size_t arity;
    rducks_type_id_t *args;
    size_t *arg_sizes;
    rducks_type_id_t returns;
    size_t return_size;
    rducks_null_handling_t null_handling;
    rducks_exception_handling_t exception_handling;
} rducks_r_scalar_meta_t;

static duckdb_database g_database = NULL;
static duckdb_connection g_connection = NULL;
static int g_registration_surface_ready = 0;

static char *rducks_copy_duckdb_string(duckdb_string_t *s) {
    uint32_t len = duckdb_string_t_length(*s);
    const char *data = duckdb_string_t_data(s);
    char *out = (char *)malloc((size_t)len + 1U);
    if (!out) {
        return NULL;
    }
    memcpy(out, data, (size_t)len);
    out[len] = '\0';
    return out;
}

static void rducks_ascii_lower_inplace(char *x) {
    for (; x && *x; ++x) {
        if (*x >= 'A' && *x <= 'Z') {
            *x = (char)(*x - 'A' + 'a');
        }
    }
}

static char *rducks_trim_ascii(char *x) {
    char *end;
    while (*x == ' ' || *x == '\t' || *x == '\n' || *x == '\r') {
        x++;
    }
    if (*x == '\0') {
        return x;
    }
    end = x + strlen(x) - 1U;
    while (end > x && (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r')) {
        *end = '\0';
        end--;
    }
    return x;
}

static rducks_type_id_t rducks_type_from_token(const char *raw_token) {
    char token[64];
    size_t len;
    if (!raw_token) {
        return RDUCKS_TYPE_INVALID;
    }
    while (*raw_token == ' ' || *raw_token == '\t' || *raw_token == '\n' || *raw_token == '\r') {
        raw_token++;
    }
    if (strncmp(raw_token, "duckdb_", 7U) == 0 || strncmp(raw_token, "DUCKDB_", 7U) == 0) {
        raw_token += 7;
    }
    len = strlen(raw_token);
    while (len > 0 && (raw_token[len - 1U] == ' ' || raw_token[len - 1U] == '\t' ||
                       raw_token[len - 1U] == '\n' || raw_token[len - 1U] == '\r')) {
        len--;
    }
    if (len == 0 || len >= sizeof(token)) {
        return RDUCKS_TYPE_INVALID;
    }
    memcpy(token, raw_token, len);
    token[len] = '\0';
    rducks_ascii_lower_inplace(token);

    if (strcmp(token, "bool") == 0 || strcmp(token, "logical") == 0 || strcmp(token, "boolean") == 0) {
        return RDUCKS_TYPE_BOOL;
    }
    if (strcmp(token, "i8") == 0 || strcmp(token, "int8") == 0 || strcmp(token, "tinyint") == 0 ||
        strcmp(token, "byte") == 0) {
        return RDUCKS_TYPE_I8;
    }
    if (strcmp(token, "u8") == 0 || strcmp(token, "uint8") == 0 || strcmp(token, "utinyint") == 0 ||
        strcmp(token, "unsigned_byte") == 0) {
        return RDUCKS_TYPE_U8;
    }
    if (strcmp(token, "i16") == 0 || strcmp(token, "int16") == 0 || strcmp(token, "smallint") == 0) {
        return RDUCKS_TYPE_I16;
    }
    if (strcmp(token, "u16") == 0 || strcmp(token, "uint16") == 0 || strcmp(token, "usmallint") == 0) {
        return RDUCKS_TYPE_U16;
    }
    if (strcmp(token, "i32") == 0 || strcmp(token, "int") == 0 || strcmp(token, "integer") == 0 ||
        strcmp(token, "int32") == 0) {
        return RDUCKS_TYPE_I32;
    }
    if (strcmp(token, "u32") == 0 || strcmp(token, "uint") == 0 || strcmp(token, "uint32") == 0 ||
        strcmp(token, "uinteger") == 0) {
        return RDUCKS_TYPE_U32;
    }
    if (strcmp(token, "i64") == 0 || strcmp(token, "int64") == 0 || strcmp(token, "bigint") == 0) {
        return RDUCKS_TYPE_I64;
    }
    if (strcmp(token, "u64") == 0 || strcmp(token, "uint64") == 0 || strcmp(token, "ubigint") == 0) {
        return RDUCKS_TYPE_U64;
    }
    if (strcmp(token, "f32") == 0 || strcmp(token, "float") == 0) {
        return RDUCKS_TYPE_F32;
    }
    if (strcmp(token, "f64") == 0 || strcmp(token, "double") == 0 || strcmp(token, "numeric") == 0 ||
        strcmp(token, "real") == 0) {
        return RDUCKS_TYPE_F64;
    }
    if (strcmp(token, "varchar") == 0 || strcmp(token, "string") == 0 || strcmp(token, "character") == 0 ||
        strcmp(token, "cstring") == 0) {
        return RDUCKS_TYPE_VARCHAR;
    }
    if (strcmp(token, "blob") == 0 || strcmp(token, "raw") == 0 || strcmp(token, "binary") == 0) {
        return RDUCKS_TYPE_BLOB;
    }
    if (strcmp(token, "date") == 0) {
        return RDUCKS_TYPE_DATE;
    }
    if (strcmp(token, "time") == 0) {
        return RDUCKS_TYPE_TIME;
    }
    if (strcmp(token, "timestamp") == 0 || strcmp(token, "posixct") == 0 || strcmp(token, "datetime") == 0) {
        return RDUCKS_TYPE_TIMESTAMP;
    }
    return RDUCKS_TYPE_INVALID;
}

static size_t rducks_type_size(rducks_type_id_t type) {
    switch (type) {
    case RDUCKS_TYPE_BOOL:
        return sizeof(bool);
    case RDUCKS_TYPE_I8:
        return sizeof(int8_t);
    case RDUCKS_TYPE_U8:
        return sizeof(uint8_t);
    case RDUCKS_TYPE_I16:
        return sizeof(int16_t);
    case RDUCKS_TYPE_U16:
        return sizeof(uint16_t);
    case RDUCKS_TYPE_I32:
        return sizeof(int32_t);
    case RDUCKS_TYPE_U32:
        return sizeof(uint32_t);
    case RDUCKS_TYPE_I64:
        return sizeof(int64_t);
    case RDUCKS_TYPE_U64:
        return sizeof(uint64_t);
    case RDUCKS_TYPE_F32:
        return sizeof(float);
    case RDUCKS_TYPE_F64:
        return sizeof(double);
    case RDUCKS_TYPE_VARCHAR:
        return sizeof(const char *);
    case RDUCKS_TYPE_BLOB:
        return sizeof(rducks_blob_t);
    case RDUCKS_TYPE_DATE:
        return sizeof(duckdb_date);
    case RDUCKS_TYPE_TIME:
        return sizeof(duckdb_time);
    case RDUCKS_TYPE_TIMESTAMP:
        return sizeof(duckdb_timestamp);
    default:
        return 0U;
    }
}

static duckdb_type rducks_duckdb_type_id(rducks_type_id_t type) {
    switch (type) {
    case RDUCKS_TYPE_BOOL:
        return DUCKDB_TYPE_BOOLEAN;
    case RDUCKS_TYPE_I8:
        return DUCKDB_TYPE_TINYINT;
    case RDUCKS_TYPE_U8:
        return DUCKDB_TYPE_UTINYINT;
    case RDUCKS_TYPE_I16:
        return DUCKDB_TYPE_SMALLINT;
    case RDUCKS_TYPE_U16:
        return DUCKDB_TYPE_USMALLINT;
    case RDUCKS_TYPE_I32:
        return DUCKDB_TYPE_INTEGER;
    case RDUCKS_TYPE_U32:
        return DUCKDB_TYPE_UINTEGER;
    case RDUCKS_TYPE_I64:
        return DUCKDB_TYPE_BIGINT;
    case RDUCKS_TYPE_U64:
        return DUCKDB_TYPE_UBIGINT;
    case RDUCKS_TYPE_F32:
        return DUCKDB_TYPE_FLOAT;
    case RDUCKS_TYPE_F64:
        return DUCKDB_TYPE_DOUBLE;
    case RDUCKS_TYPE_VARCHAR:
        return DUCKDB_TYPE_VARCHAR;
    case RDUCKS_TYPE_BLOB:
        return DUCKDB_TYPE_BLOB;
    case RDUCKS_TYPE_DATE:
        return DUCKDB_TYPE_DATE;
    case RDUCKS_TYPE_TIME:
        return DUCKDB_TYPE_TIME;
    case RDUCKS_TYPE_TIMESTAMP:
        return DUCKDB_TYPE_TIMESTAMP;
    default:
        return DUCKDB_TYPE_INVALID;
    }
}

static duckdb_logical_type rducks_create_logical_type_for_id(rducks_type_id_t type) {
    duckdb_type duckdb_type_id = rducks_duckdb_type_id(type);
    if (duckdb_type_id == DUCKDB_TYPE_INVALID) {
        return NULL;
    }
    return duckdb_create_logical_type(duckdb_type_id);
}

static int rducks_parse_null_handling(const char *text, rducks_null_handling_t *out, char *err, size_t err_cap) {
    char token[32];
    size_t len;
    if (!text || !out) {
        snprintf(err, err_cap, "invalid null_handling value");
        return 0;
    }
    while (*text == ' ' || *text == '\t' || *text == '\n' || *text == '\r') {
        text++;
    }
    len = strlen(text);
    while (len > 0 && (text[len - 1U] == ' ' || text[len - 1U] == '\t' || text[len - 1U] == '\n' ||
                       text[len - 1U] == '\r')) {
        len--;
    }
    if (len == 0 || len >= sizeof(token)) {
        snprintf(err, err_cap, "invalid null_handling value");
        return 0;
    }
    memcpy(token, text, len);
    token[len] = '\0';
    rducks_ascii_lower_inplace(token);
    if (strcmp(token, "default") == 0 || strcmp(token, "null_in_null_out") == 0) {
        *out = RDUCKS_NULL_DEFAULT;
        return 1;
    }
    if (strcmp(token, "special") == 0) {
        *out = RDUCKS_NULL_SPECIAL;
        return 1;
    }
    snprintf(err, err_cap, "unsupported null_handling value: %s", token);
    return 0;
}

static int rducks_parse_exception_handling(const char *text, rducks_exception_handling_t *out, char *err,
                                           size_t err_cap) {
    char token[32];
    size_t len;
    if (!text || !out) {
        snprintf(err, err_cap, "invalid exception_handling value");
        return 0;
    }
    while (*text == ' ' || *text == '\t' || *text == '\n' || *text == '\r') {
        text++;
    }
    len = strlen(text);
    while (len > 0 && (text[len - 1U] == ' ' || text[len - 1U] == '\t' || text[len - 1U] == '\n' ||
                       text[len - 1U] == '\r')) {
        len--;
    }
    if (len == 0 || len >= sizeof(token)) {
        snprintf(err, err_cap, "invalid exception_handling value");
        return 0;
    }
    memcpy(token, text, len);
    token[len] = '\0';
    rducks_ascii_lower_inplace(token);
    if (strcmp(token, "rethrow") == 0 || strcmp(token, "error") == 0) {
        *out = RDUCKS_EXCEPTION_RETHROW;
        return 1;
    }
    if (strcmp(token, "return_null") == 0 || strcmp(token, "return-null") == 0) {
        *out = RDUCKS_EXCEPTION_RETURN_NULL;
        return 1;
    }
    snprintf(err, err_cap, "unsupported exception_handling value: %s", token);
    return 0;
}

static int rducks_parse_type_list(const char *text, rducks_type_id_t **out, size_t *out_count, char *err, size_t err_cap) {
    char *copy;
    char *cursor;
    rducks_type_id_t *items = NULL;
    size_t count = 0;
    size_t capacity = 0;
    if (!text || !out || !out_count) {
        snprintf(err, err_cap, "invalid type list");
        return 0;
    }
    *out = NULL;
    *out_count = 0;
    if (text[0] == '\0') {
        return 1;
    }
    copy = (char *)malloc(strlen(text) + 1U);
    if (!copy) {
        snprintf(err, err_cap, "out of memory");
        return 0;
    }
    strcpy(copy, text);
    cursor = copy;
    while (cursor) {
        char *next = strchr(cursor, ',');
        char *token;
        rducks_type_id_t type;
        if (next) {
            *next = '\0';
            next++;
        }
        token = rducks_trim_ascii(cursor);
        type = rducks_type_from_token(token);
        if (type == RDUCKS_TYPE_INVALID) {
            snprintf(err, err_cap, "unsupported Rducks argument type: %s", token);
            free(items);
            free(copy);
            return 0;
        }
        if (count == capacity) {
            size_t new_capacity = capacity == 0U ? 4U : capacity * 2U;
            rducks_type_id_t *new_items;
            if (new_capacity <= capacity || new_capacity > (SIZE_MAX / sizeof(rducks_type_id_t))) {
                snprintf(err, err_cap, "UDF argument list is too large to allocate");
                free(items);
                free(copy);
                return 0;
            }
            new_items = (rducks_type_id_t *)realloc(items, sizeof(rducks_type_id_t) * new_capacity);
            if (!new_items) {
                snprintf(err, err_cap, "out of memory");
                free(items);
                free(copy);
                return 0;
            }
            items = new_items;
            capacity = new_capacity;
        }
        items[count++] = type;
        cursor = next;
    }
    free(copy);
    *out = items;
    *out_count = count;
    return 1;
}

static void rducks_r_scalar_meta_destroy(void *ptr) {
    rducks_r_scalar_meta_t *meta = (rducks_r_scalar_meta_t *)ptr;
    if (!meta) {
        return;
    }
    if (meta->fun != R_NilValue) {
        R_ReleaseObject(meta->fun);
    }
    free(meta->args);
    free(meta->arg_sizes);
    free(meta);
}

static void rducks_output_set_null(duckdb_vector output, idx_t row) {
    uint64_t *validity;
    duckdb_vector_ensure_validity_writable(output);
    validity = duckdb_vector_get_validity(output);
    duckdb_validity_set_row_invalid(validity, row);
}

static void rducks_output_set_valid(duckdb_vector output, idx_t row) {
    uint64_t *validity = duckdb_vector_get_validity(output);
    if (validity) {
        duckdb_validity_set_row_valid(validity, row);
    }
}

static void rducks_version_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    (void)info;
    idx_t n = duckdb_data_chunk_get_size(input);
    for (idx_t i = 0; i < n; i++) {
        duckdb_vector_assign_string_element(output, i, "Rducks extension loaded");
    }
}

static int rducks_prepare_arg(rducks_type_id_t type, duckdb_vector vector, idx_t row, bool *is_null, void **arg_ptr,
                              void **arg_alloc) {
    uint64_t *validity = duckdb_vector_get_validity(vector);
    uint8_t *data = (uint8_t *)duckdb_vector_get_data(vector);
    size_t size = rducks_type_size(type);
    *is_null = false;
    *arg_ptr = NULL;
    *arg_alloc = NULL;
    if (validity && !duckdb_validity_row_is_valid(validity, row)) {
        *is_null = true;
        return 1;
    }
    if (type == RDUCKS_TYPE_VARCHAR) {
        duckdb_string_t *strings = (duckdb_string_t *)data;
        char *copy = rducks_copy_duckdb_string(&strings[row]);
        if (!copy) {
            return 0;
        }
        *arg_alloc = copy;
        *arg_ptr = (void *)arg_alloc;
        return 1;
    }
    if (type == RDUCKS_TYPE_BLOB) {
        duckdb_string_t *strings = (duckdb_string_t *)data;
        rducks_blob_t *blob = (rducks_blob_t *)malloc(sizeof(rducks_blob_t));
        if (!blob) {
            return 0;
        }
        blob->len = (uint64_t)duckdb_string_t_length(strings[row]);
        blob->ptr = (const uint8_t *)duckdb_string_t_data(&strings[row]);
        *arg_alloc = blob;
        *arg_ptr = (void *)blob;
        return 1;
    }
    if (size == 0U) {
        return 0;
    }
    *arg_ptr = (void *)(data + ((size_t)row * size));
    return 1;
}

static void rducks_write_compiled_result(rducks_r_scalar_meta_t *meta, duckdb_vector output, idx_t row, void *out_value,
                                         bool out_is_null) {
    if (out_is_null) {
        rducks_output_set_null(output, row);
        return;
    }
    if (meta->returns == RDUCKS_TYPE_VARCHAR) {
        char *value = *(char **)out_value;
        if (!value) {
            rducks_output_set_null(output, row);
            return;
        }
        duckdb_vector_assign_string_element(output, row, value);
        free(value);
        rducks_output_set_valid(output, row);
        return;
    }
    if (meta->returns == RDUCKS_TYPE_BLOB) {
        rducks_blob_t *value = (rducks_blob_t *)out_value;
        if (!value->ptr && value->len > 0U) {
            rducks_output_set_null(output, row);
            return;
        }
        duckdb_vector_assign_string_element_len(output, row, value->ptr ? (const char *)value->ptr : "", (idx_t)value->len);
        free((void *)value->ptr);
        rducks_output_set_valid(output, row);
        return;
    }
    if (meta->return_size > 0U) {
        uint8_t *out_data = (uint8_t *)duckdb_vector_get_data(output);
        memcpy(out_data + ((size_t)row * meta->return_size), out_value, meta->return_size);
    }
    rducks_output_set_valid(output, row);
}

static void rducks_compiled_scalar_udf(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_r_scalar_meta_t *meta = (rducks_r_scalar_meta_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n;
    void **arg_ptrs = NULL;
    bool *arg_is_null = NULL;
    void **arg_allocs = NULL;
    if (!meta || !meta->fun || !meta->wrapper) {
        duckdb_scalar_function_set_error(info, "Rducks compiled scalar metadata missing");
        return;
    }
    n = duckdb_data_chunk_get_size(input);
    duckdb_vector_ensure_validity_writable(output);

    if (meta->arity > 0) {
        if (meta->arity > (SIZE_MAX / sizeof(void *)) || meta->arity > (SIZE_MAX / sizeof(bool)) ||
            meta->arity > (SIZE_MAX / sizeof(void *))) {
            duckdb_scalar_function_set_error(info, "Rducks argument list is too large to allocate");
            return;
        }
        arg_ptrs = (void **)malloc(sizeof(void *) * meta->arity);
        arg_is_null = (bool *)malloc(sizeof(bool) * meta->arity);
        arg_allocs = (void **)malloc(sizeof(void *) * meta->arity);
        if (!arg_ptrs || !arg_is_null || !arg_allocs) {
            free(arg_ptrs);
            free(arg_is_null);
            free(arg_allocs);
            duckdb_scalar_function_set_error(info, "out of memory");
            return;
        }
    }

    for (idx_t row = 0; row < n; row++) {
        uint8_t out_value[32];
        bool out_is_null = false;
        int ok = 1;
        if (meta->return_size > sizeof(out_value)) {
            free(arg_ptrs);
            free(arg_is_null);
            free(arg_allocs);
            duckdb_scalar_function_set_error(info, "Rducks return type is too large for scalar bridge");
            return;
        }
        if (meta->arity > 0) {
            memset(arg_allocs, 0, sizeof(void *) * meta->arity);
            for (size_t col = 0; col < meta->arity; col++) {
                duckdb_vector vector = duckdb_data_chunk_get_vector(input, (idx_t)col);
                if (!rducks_prepare_arg(meta->args[col], vector, row, &arg_is_null[col], &arg_ptrs[col],
                                        &arg_allocs[col])) {
                    ok = 0;
                    break;
                }
            }
        }
        if (!ok) {
            if (arg_allocs) {
                for (size_t col = 0; col < meta->arity; col++) {
                    free(arg_allocs[col]);
                }
            }
            free(arg_ptrs);
            free(arg_is_null);
            free(arg_allocs);
            duckdb_scalar_function_set_error(info, "out of memory preparing Rducks arguments");
            return;
        }
        if (meta->null_handling == RDUCKS_NULL_DEFAULT) {
            int has_null = 0;
            for (size_t col = 0; col < meta->arity; col++) {
                if (arg_is_null[col]) {
                    has_null = 1;
                    break;
                }
            }
            if (has_null) {
                rducks_output_set_null(output, row);
                if (arg_allocs) {
                    for (size_t col = 0; col < meta->arity; col++) {
                        free(arg_allocs[col]);
                    }
                }
                continue;
            }
        }
        memset(out_value, 0, sizeof(out_value));
        if (!meta->wrapper(meta->fun, arg_ptrs, arg_is_null, (void *)out_value, &out_is_null)) {
            if (meta->exception_handling == RDUCKS_EXCEPTION_RETURN_NULL) {
                rducks_output_set_null(output, row);
                if (arg_allocs) {
                    for (size_t col = 0; col < meta->arity; col++) {
                        free(arg_allocs[col]);
                    }
                }
                continue;
            }
            if (arg_allocs) {
                for (size_t col = 0; col < meta->arity; col++) {
                    free(arg_allocs[col]);
                }
            }
            free(arg_ptrs);
            free(arg_is_null);
            free(arg_allocs);
            duckdb_scalar_function_set_error(info, "Rducks compiled callback raised an error");
            return;
        }
        rducks_write_compiled_result(meta, output, row, (void *)out_value, out_is_null);
        if (arg_allocs) {
            for (size_t col = 0; col < meta->arity; col++) {
                free(arg_allocs[col]);
            }
        }
    }

    free(arg_ptrs);
    free(arg_is_null);
    free(arg_allocs);
}

static bool rducks_register_r_scalar(const char *name, SEXP fun, void *wrapper_ptr, const char *args_spec,
                                     const char *return_spec, const char *null_handling_spec,
                                     const char *exception_handling_spec, bool side_effects, char *err,
                                     size_t err_cap) {
    rducks_type_id_t *arg_types = NULL;
    size_t arity = 0;
    rducks_type_id_t return_type;
    rducks_null_handling_t null_handling;
    rducks_exception_handling_t exception_handling;
    rducks_r_scalar_meta_t *meta = NULL;
    duckdb_scalar_function fn = NULL;
    duckdb_logical_type return_logical_type = NULL;
    duckdb_state rc;
    if (!g_connection || !name || !name[0] || !Rf_isFunction(fun) || !wrapper_ptr) {
        snprintf(err, err_cap, "invalid Rducks scalar registration request");
        return false;
    }
    if (!rducks_parse_type_list(args_spec, &arg_types, &arity, err, err_cap)) {
        return false;
    }
    return_type = rducks_type_from_token(return_spec);
    if (return_type == RDUCKS_TYPE_INVALID) {
        snprintf(err, err_cap, "unsupported Rducks return type: %s", return_spec ? return_spec : "<null>");
        free(arg_types);
        return false;
    }
    if (!rducks_parse_null_handling(null_handling_spec, &null_handling, err, err_cap)) {
        free(arg_types);
        return false;
    }
    if (!rducks_parse_exception_handling(exception_handling_spec, &exception_handling, err, err_cap)) {
        free(arg_types);
        return false;
    }

    fn = duckdb_create_scalar_function();
    return_logical_type = rducks_create_logical_type_for_id(return_type);
    if (!fn || !return_logical_type) {
        snprintf(err, err_cap, "failed to allocate DuckDB scalar function for Rducks UDF");
        if (fn) {
            duckdb_destroy_scalar_function(&fn);
        }
        if (return_logical_type) {
            duckdb_destroy_logical_type(&return_logical_type);
        }
        free(arg_types);
        return false;
    }

    duckdb_scalar_function_set_name(fn, name);
    for (size_t i = 0; i < arity; i++) {
        duckdb_logical_type arg_logical_type = rducks_create_logical_type_for_id(arg_types[i]);
        if (!arg_logical_type) {
            snprintf(err, err_cap, "failed to allocate DuckDB logical type for Rducks argument %zu", i + 1);
            duckdb_destroy_scalar_function(&fn);
            duckdb_destroy_logical_type(&return_logical_type);
            free(arg_types);
            return false;
        }
        duckdb_scalar_function_add_parameter(fn, arg_logical_type);
        duckdb_destroy_logical_type(&arg_logical_type);
    }

    meta = (rducks_r_scalar_meta_t *)calloc(1, sizeof(rducks_r_scalar_meta_t));
    if (!meta) {
        snprintf(err, err_cap, "out of memory");
        duckdb_destroy_scalar_function(&fn);
        duckdb_destroy_logical_type(&return_logical_type);
        free(arg_types);
        return false;
    }
    meta->fun = R_NilValue;
    meta->wrapper = (rducks_scalar_wrapper_fn_t)wrapper_ptr;
    meta->arity = arity;
    meta->args = arg_types;
    arg_types = NULL;
    meta->returns = return_type;
    meta->return_size = rducks_type_size(return_type);
    meta->null_handling = null_handling;
    meta->exception_handling = exception_handling;
    if (arity > 0) {
        meta->arg_sizes = (size_t *)calloc(arity, sizeof(size_t));
        if (!meta->arg_sizes) {
            snprintf(err, err_cap, "out of memory");
            rducks_r_scalar_meta_destroy(meta);
            duckdb_destroy_scalar_function(&fn);
            duckdb_destroy_logical_type(&return_logical_type);
            return false;
        }
    }
    for (size_t i = 0; i < arity; i++) {
        meta->arg_sizes[i] = rducks_type_size(meta->args[i]);
    }
    meta->fun = fun;
    R_PreserveObject(fun);

    duckdb_scalar_function_set_return_type(fn, return_logical_type);
    if (null_handling == RDUCKS_NULL_SPECIAL) {
        duckdb_scalar_function_set_special_handling(fn);
    }
    if (side_effects) {
        duckdb_scalar_function_set_volatile(fn);
    }
    duckdb_scalar_function_set_extra_info(fn, meta, rducks_r_scalar_meta_destroy);
    duckdb_scalar_function_set_function(fn, rducks_compiled_scalar_udf);
    rc = duckdb_register_scalar_function(g_connection, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&return_logical_type);
    if (rc != DuckDBSuccess) {
        snprintf(err, err_cap, "DuckDB failed to register Rducks scalar UDF %s", name);
        return false;
    }
    return true;
}

static void rducks_register_scalar_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    idx_t n = duckdb_data_chunk_get_size(input);
    duckdb_string_t *names = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 0));
    uint64_t *fun_ptrs = (uint64_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 1));
    uint64_t *wrapper_ptrs = (uint64_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 2));
    duckdb_string_t *args_specs = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 3));
    duckdb_string_t *return_specs = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 4));
    duckdb_string_t *null_handling_specs =
        (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 5));
    duckdb_string_t *exception_handling_specs =
        (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 6));
    bool *side_effects_values = (bool *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 7));
    bool *out = (bool *)duckdb_vector_get_data(output);

    for (idx_t i = 0; i < n; i++) {
        char *name = rducks_copy_duckdb_string(&names[i]);
        char *args_spec = rducks_copy_duckdb_string(&args_specs[i]);
        char *return_spec = rducks_copy_duckdb_string(&return_specs[i]);
        char *null_handling_spec = rducks_copy_duckdb_string(&null_handling_specs[i]);
        char *exception_handling_spec = rducks_copy_duckdb_string(&exception_handling_specs[i]);
        char err[256];
        SEXP fun;
        void *wrapper_ptr;
        err[0] = '\0';
        if (!name || !args_spec || !return_spec || !null_handling_spec || !exception_handling_spec) {
            free(name);
            free(args_spec);
            free(return_spec);
            free(null_handling_spec);
            free(exception_handling_spec);
            duckdb_scalar_function_set_error(info, "out of memory");
            return;
        }
        fun = (SEXP)(uintptr_t)fun_ptrs[i];
        wrapper_ptr = (void *)(uintptr_t)wrapper_ptrs[i];
        out[i] = rducks_register_r_scalar(name, fun, wrapper_ptr, args_spec, return_spec, null_handling_spec,
                                          exception_handling_spec, side_effects_values[i], err, sizeof(err));
        free(name);
        free(args_spec);
        free(return_spec);
        free(null_handling_spec);
        free(exception_handling_spec);
        if (!out[i]) {
            duckdb_scalar_function_set_error(info, err[0] ? err : "Rducks scalar registration failed");
            return;
        }
    }
}

static bool rducks_register_scalar_surface(duckdb_connection con) {
    duckdb_scalar_function fn = duckdb_create_scalar_function();
    duckdb_logical_type varchar_type = duckdb_create_logical_type(DUCKDB_TYPE_VARCHAR);
    duckdb_logical_type ubigint_type = duckdb_create_logical_type(DUCKDB_TYPE_UBIGINT);
    duckdb_logical_type bool_type = duckdb_create_logical_type(DUCKDB_TYPE_BOOLEAN);
    duckdb_state rc;
    if (!fn || !varchar_type || !ubigint_type || !bool_type) {
        if (fn) {
            duckdb_destroy_scalar_function(&fn);
        }
        if (varchar_type) {
            duckdb_destroy_logical_type(&varchar_type);
        }
        if (ubigint_type) {
            duckdb_destroy_logical_type(&ubigint_type);
        }
        if (bool_type) {
            duckdb_destroy_logical_type(&bool_type);
        }
        return false;
    }
    duckdb_scalar_function_set_name(fn, "rducks_register_scalar");
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, ubigint_type);
    duckdb_scalar_function_add_parameter(fn, ubigint_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, bool_type);
    duckdb_scalar_function_set_return_type(fn, bool_type);
    duckdb_scalar_function_set_volatile(fn);
    duckdb_scalar_function_set_function(fn, rducks_register_scalar_scalar);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&varchar_type);
    duckdb_destroy_logical_type(&ubigint_type);
    duckdb_destroy_logical_type(&bool_type);
    return rc == DuckDBSuccess;
}

static bool rducks_register_version(duckdb_connection con) {
    duckdb_scalar_function fn = duckdb_create_scalar_function();
    duckdb_logical_type varchar_type = duckdb_create_logical_type(DUCKDB_TYPE_VARCHAR);
    duckdb_state rc;
    if (!fn || !varchar_type) {
        if (fn) {
            duckdb_destroy_scalar_function(&fn);
        }
        if (varchar_type) {
            duckdb_destroy_logical_type(&varchar_type);
        }
        return false;
    }
    duckdb_scalar_function_set_name(fn, "rducks_version");
    duckdb_scalar_function_set_return_type(fn, varchar_type);
    duckdb_scalar_function_set_function(fn, rducks_version_scalar);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_logical_type(&varchar_type);
    duckdb_destroy_scalar_function(&fn);
    return rc == DuckDBSuccess;
}

DUCKDB_EXTENSION_ENTRYPOINT_CUSTOM(duckdb_extension_info info, struct duckdb_extension_access *access) {
    duckdb_database database = NULL;
    if (access && info) {
        duckdb_database *db_ptr = access->get_database(info);
        if (db_ptr) {
            database = *db_ptr;
        }
    }
    if (!database) {
        if (access) {
            access->set_error(info, "failed to get database handle");
        }
        return false;
    }
    if (!g_connection || g_database != database) {
        if (duckdb_connect(database, &g_connection) == DuckDBError || !g_connection) {
            if (access) {
                access->set_error(info, "failed to open Rducks persistent connection");
            }
            return false;
        }
        g_database = database;
        g_registration_surface_ready = 0;
    }
    if (!g_registration_surface_ready) {
        if (!rducks_register_version(g_connection) || !rducks_register_scalar_surface(g_connection)) {
            if (access) {
                access->set_error(info, "failed to register Rducks SQL surface");
            }
            return false;
        }
        g_registration_surface_ready = 1;
    }
    return true;
}
