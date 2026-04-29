/* Rducks DuckDB extension
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "duckdb_extension.h"

#include <R.h>
#include <Rinternals.h>
#include <R_ext/Arith.h>

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
    RDUCKS_TYPE_TIMESTAMP,
    RDUCKS_TYPE_HUGEINT,
    RDUCKS_TYPE_UHUGEINT,
    RDUCKS_TYPE_UUID,
    RDUCKS_TYPE_INTERVAL,
    RDUCKS_TYPE_BIT
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
    SEXP compiled;
    rducks_scalar_wrapper_fn_t wrapper;
    size_t arity;
    struct rducks_type_desc **args;
    size_t *arg_sizes;
    struct rducks_type_desc *return_desc;
    rducks_type_id_t returns;
    size_t return_size;
    rducks_null_handling_t null_handling;
    rducks_exception_handling_t exception_handling;
} rducks_r_scalar_meta_t;

typedef struct rducks_inactive_scalar_meta {
    char *name;
} rducks_inactive_scalar_meta_t;

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

static void rducks_const_trim(const char **x, size_t *len) {
    while (*len > 0 && (**x == ' ' || **x == '\t' || **x == '\n' || **x == '\r')) {
        (*x)++;
        (*len)--;
    }
    while (*len > 0 && ((*x)[*len - 1U] == ' ' || (*x)[*len - 1U] == '\t' || (*x)[*len - 1U] == '\n' ||
                        (*x)[*len - 1U] == '\r')) {
        (*len)--;
    }
}

static void rducks_set_class1(SEXP x, const char *klass) {
    SEXP cls = PROTECT(Rf_mkString(klass));
    Rf_classgets(x, cls);
    UNPROTECT(1);
}

static void rducks_set_class2(SEXP x, const char *klass1, const char *klass2) {
    SEXP cls = PROTECT(Rf_allocVector(STRSXP, 2));
    SET_STRING_ELT(cls, 0, Rf_mkChar(klass1));
    SET_STRING_ELT(cls, 1, Rf_mkChar(klass2));
    Rf_classgets(x, cls);
    UNPROTECT(1);
}

static int rducks_hex_value(char ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return 10 + ch - 'a';
    if (ch >= 'A' && ch <= 'F') return 10 + ch - 'A';
    return -1;
}

static void rducks_u128_to_decimal(unsigned __int128 value, char *out) {
    char tmp[64];
    size_t n = 0;
    if (value == 0) {
        out[0] = '0';
        out[1] = '\0';
        return;
    }
    while (value > 0) {
        tmp[n++] = (char)('0' + (int)(value % 10));
        value /= 10;
    }
    for (size_t i = 0; i < n; i++) out[i] = tmp[n - i - 1U];
    out[n] = '\0';
}

static unsigned __int128 rducks_pow10_u128(uint8_t n) {
    unsigned __int128 out = 1;
    for (uint8_t i = 0; i < n; i++) out *= 10;
    return out;
}

static unsigned __int128 rducks_hugeint_bits(duckdb_hugeint value) {
    return (((unsigned __int128)(uint64_t)value.upper) << 64) | (unsigned __int128)value.lower;
}

static duckdb_hugeint rducks_hugeint_from_bits(unsigned __int128 bits) {
    duckdb_hugeint out;
    out.lower = (uint64_t)bits;
    out.upper = (int64_t)(uint64_t)(bits >> 64);
    return out;
}

static duckdb_uhugeint rducks_uhugeint_from_bits(unsigned __int128 bits) {
    duckdb_uhugeint out;
    out.lower = (uint64_t)bits;
    out.upper = (uint64_t)(bits >> 64);
    return out;
}

static unsigned __int128 rducks_uhugeint_bits(duckdb_uhugeint value) {
    return (((unsigned __int128)value.upper) << 64) | (unsigned __int128)value.lower;
}

static __int128 rducks_hugeint_to_i128(duckdb_hugeint value) {
    return (__int128)rducks_hugeint_bits(value);
}

static duckdb_hugeint rducks_hugeint_from_i128(__int128 value) {
    return rducks_hugeint_from_bits((unsigned __int128)value);
}

static void rducks_hugeint_to_string(duckdb_hugeint value, char *out) {
    unsigned __int128 bits = rducks_hugeint_bits(value);
    if (value.upper < 0) {
        out[0] = '-';
        rducks_u128_to_decimal((unsigned __int128)(0 - bits), out + 1);
    } else {
        rducks_u128_to_decimal(bits, out);
    }
}

static void rducks_uhugeint_to_string(duckdb_uhugeint value, char *out) {
    rducks_u128_to_decimal(rducks_uhugeint_bits(value), out);
}

static int rducks_parse_hugeint_text(const char *text, duckdb_hugeint *out) {
    size_t len;
    size_t i = 0;
    int negative = 0;
    int saw_digit = 0;
    unsigned __int128 value = 0;
    const unsigned __int128 signed_min_abs = ((unsigned __int128)1) << 127;
    unsigned __int128 limit;
    if (!text || !out) return 0;
    len = strlen(text);
    rducks_const_trim(&text, &len);
    if (i < len && (text[i] == '+' || text[i] == '-')) {
        negative = text[i] == '-';
        i++;
    }
    limit = negative ? signed_min_abs : signed_min_abs - 1U;
    for (; i < len; i++) {
        int digit;
        if (text[i] < '0' || text[i] > '9') return 0;
        digit = text[i] - '0';
        saw_digit = 1;
        if (value > (limit - (unsigned)digit) / 10U) return 0;
        value = value * 10U + (unsigned)digit;
    }
    if (!saw_digit) return 0;
    *out = rducks_hugeint_from_bits(negative ? (unsigned __int128)(0 - value) : value);
    return 1;
}

static int rducks_parse_uhugeint_text(const char *text, duckdb_uhugeint *out) {
    size_t len;
    size_t i = 0;
    int saw_digit = 0;
    unsigned __int128 value = 0;
    const unsigned __int128 max_value = ~(unsigned __int128)0;
    if (!text || !out) return 0;
    len = strlen(text);
    rducks_const_trim(&text, &len);
    if (i < len && text[i] == '+') i++;
    if (i < len && text[i] == '-') return 0;
    for (; i < len; i++) {
        int digit;
        if (text[i] < '0' || text[i] > '9') return 0;
        digit = text[i] - '0';
        saw_digit = 1;
        if (value > (max_value - (unsigned)digit) / 10U) return 0;
        value = value * 10U + (unsigned)digit;
    }
    if (!saw_digit) return 0;
    *out = rducks_uhugeint_from_bits(value);
    return 1;
}

static int rducks_parse_uuid_text(const char *text, duckdb_hugeint *out) {
    uint64_t upper = 0;
    uint64_t lower = 0;
    size_t len;
    size_t count = 0;
    if (!text || !out) return 0;
    len = strlen(text);
    rducks_const_trim(&text, &len);
    if (len != 36 || text[8] != '-' || text[13] != '-' || text[18] != '-' || text[23] != '-') return 0;
    for (size_t i = 0; i < len; i++) {
        int hex;
        if (text[i] == '-') continue;
        hex = rducks_hex_value(text[i]);
        if (hex < 0 || count >= 32) return 0;
        if (count < 16) upper = (upper << 4) | (uint64_t)hex;
        else lower = (lower << 4) | (uint64_t)hex;
        count++;
    }
    if (count != 32) return 0;
    upper ^= UINT64_C(0x8000000000000000);
    out->upper = (int64_t)upper;
    out->lower = lower;
    return 1;
}

static void rducks_uuid_to_string(duckdb_hugeint input, char *out) {
    static const char hex[] = "0123456789abcdef";
    uint64_t upper = ((uint64_t)input.upper) ^ UINT64_C(0x8000000000000000);
    uint64_t lower = input.lower;
    uint8_t bytes[16];
    size_t pos = 0;
    for (int i = 0; i < 8; i++) bytes[i] = (uint8_t)(upper >> (56 - 8 * i));
    for (int i = 0; i < 8; i++) bytes[8 + i] = (uint8_t)(lower >> (56 - 8 * i));
    for (int i = 0; i < 16; i++) {
        if (i == 4 || i == 6 || i == 8 || i == 10) out[pos++] = '-';
        out[pos++] = hex[(bytes[i] >> 4) & 0x0f];
        out[pos++] = hex[bytes[i] & 0x0f];
    }
    out[pos] = '\0';
}

static int rducks_parse_decimal_text(const char *text, uint8_t width, uint8_t scale, duckdb_hugeint *out) {
    size_t len;
    size_t i = 0;
    int negative = 0;
    int saw_digit = 0;
    int seen_dot = 0;
    uint8_t frac = 0;
    unsigned __int128 value = 0;
    unsigned __int128 limit;
    if (!text || !out || width < 1 || width > 38 || scale > width) return 0;
    len = strlen(text);
    rducks_const_trim(&text, &len);
    if (i < len && (text[i] == '+' || text[i] == '-')) {
        negative = text[i] == '-';
        i++;
    }
    limit = rducks_pow10_u128(width) - 1U;
    for (; i < len; i++) {
        int digit;
        if (text[i] == '.') {
            if (seen_dot) return 0;
            seen_dot = 1;
            continue;
        }
        if (text[i] < '0' || text[i] > '9') return 0;
        if (seen_dot) {
            if (frac >= scale) return 0;
            frac++;
        }
        digit = text[i] - '0';
        saw_digit = 1;
        if (value > (limit - (unsigned)digit) / 10U) return 0;
        value = value * 10U + (unsigned)digit;
    }
    while (frac < scale) {
        if (value > limit / 10U) return 0;
        value *= 10U;
        frac++;
    }
    if (!saw_digit) return 0;
    *out = rducks_hugeint_from_bits(negative ? (unsigned __int128)(0 - value) : value);
    return 1;
}

static void rducks_decimal_to_string(duckdb_hugeint scaled, uint8_t scale, char *out) {
    char intbuf[80];
    const char *digits;
    int negative = 0;
    size_t len;
    if (scaled.upper < 0) negative = 1;
    rducks_hugeint_to_string(scaled, intbuf);
    digits = negative ? intbuf + 1 : intbuf;
    len = strlen(digits);
    if (negative) *out++ = '-';
    if (scale == 0) {
        strcpy(out, digits);
        return;
    }
    if (len <= scale) {
        *out++ = '0';
        *out++ = '.';
        for (size_t i = 0; i < (size_t)scale - len; i++) *out++ = '0';
        strcpy(out, digits);
    } else {
        size_t int_len = len - scale;
        memcpy(out, digits, int_len);
        out += int_len;
        *out++ = '.';
        strcpy(out, digits + int_len);
    }
}

static duckdb_hugeint rducks_decimal_storage_read(uint8_t width, void *data, idx_t row) {
    if (width <= 4) return rducks_hugeint_from_i128((__int128)((int16_t *)data)[row]);
    if (width <= 9) return rducks_hugeint_from_i128((__int128)((int32_t *)data)[row]);
    if (width <= 18) return rducks_hugeint_from_i128((__int128)((int64_t *)data)[row]);
    return ((duckdb_hugeint *)data)[row];
}

static int64_t rducks_round_double_to_i64(double value) {
    return (int64_t)(value >= 0 ? value + 0.5 : value - 0.5);
}

static int rducks_decimal_storage_write(uint8_t width, void *data, idx_t row, duckdb_hugeint value) {
    __int128 v = rducks_hugeint_to_i128(value);
    if (width <= 4) {
        if (v < -32768 || v > 32767) return 0;
        ((int16_t *)data)[row] = (int16_t)v;
    } else if (width <= 9) {
        if (v < -2147483648LL || v > 2147483647LL) return 0;
        ((int32_t *)data)[row] = (int32_t)v;
    } else if (width <= 18) {
        ((int64_t *)data)[row] = (int64_t)v;
    } else {
        ((duckdb_hugeint *)data)[row] = value;
    }
    return 1;
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
    if (strcmp(token, "hugeint") == 0) {
        return RDUCKS_TYPE_HUGEINT;
    }
    if (strcmp(token, "uhugeint") == 0) {
        return RDUCKS_TYPE_UHUGEINT;
    }
    if (strcmp(token, "uuid") == 0) {
        return RDUCKS_TYPE_UUID;
    }
    if (strcmp(token, "interval") == 0) {
        return RDUCKS_TYPE_INTERVAL;
    }
    if (strcmp(token, "bit") == 0) {
        return RDUCKS_TYPE_BIT;
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
    case RDUCKS_TYPE_HUGEINT:
    case RDUCKS_TYPE_UUID:
        return sizeof(duckdb_hugeint);
    case RDUCKS_TYPE_UHUGEINT:
        return sizeof(duckdb_uhugeint);
    case RDUCKS_TYPE_INTERVAL:
        return sizeof(duckdb_interval);
    case RDUCKS_TYPE_BIT:
        return sizeof(duckdb_string_t);
    default:
        return 0U;
    }
}

static int rducks_scalar_uses_sexp_bridge(rducks_type_id_t type) {
    switch (type) {
    case RDUCKS_TYPE_I64:
    case RDUCKS_TYPE_U64:
    case RDUCKS_TYPE_HUGEINT:
    case RDUCKS_TYPE_UHUGEINT:
    case RDUCKS_TYPE_UUID:
    case RDUCKS_TYPE_INTERVAL:
    case RDUCKS_TYPE_BIT:
        return 1;
    default:
        return 0;
    }
}

static int rducks_desc_uses_sexp_bridge(const rducks_type_desc_t *desc) {
    if (!desc) return 0;
    return desc->kind != RDUCKS_KIND_SCALAR || rducks_scalar_uses_sexp_bridge(desc->scalar);
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
    case RDUCKS_TYPE_HUGEINT:
        return DUCKDB_TYPE_HUGEINT;
    case RDUCKS_TYPE_UHUGEINT:
        return DUCKDB_TYPE_UHUGEINT;
    case RDUCKS_TYPE_UUID:
        return DUCKDB_TYPE_UUID;
    case RDUCKS_TYPE_INTERVAL:
        return DUCKDB_TYPE_INTERVAL;
    case RDUCKS_TYPE_BIT:
        return DUCKDB_TYPE_BIT;
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

static char *rducks_strdup_len(const char *x, size_t len) {
    char *out = (char *)malloc(len + 1U);
    if (!out) return NULL;
    memcpy(out, x, len);
    out[len] = '\0';
    return out;
}

static char *rducks_strdup_trimmed_len(const char *x, size_t len) {
    while (len > 0 && (*x == ' ' || *x == '\t' || *x == '\n' || *x == '\r')) {
        x++;
        len--;
    }
    while (len > 0 && (x[len - 1U] == ' ' || x[len - 1U] == '\t' || x[len - 1U] == '\n' || x[len - 1U] == '\r')) {
        len--;
    }
    return rducks_strdup_len(x, len);
}

static int rducks_is_wrapped_by_angle(const char *x, const char *prefix, const char **inner, size_t *inner_len) {
    size_t prefix_len = strlen(prefix);
    size_t len;
    int depth = 0;
    if (strncmp(x, prefix, prefix_len) != 0 || x[prefix_len] != '<') return 0;
    len = strlen(x);
    if (len <= prefix_len + 2U || x[len - 1U] != '>') return 0;
    for (size_t i = prefix_len + 1U; i < len - 1U; i++) {
        if (x[i] == '<') depth++;
        else if (x[i] == '>') {
            if (depth == 0) return 0;
            depth--;
        }
    }
    if (depth != 0) return 0;
    *inner = x + prefix_len + 1U;
    *inner_len = len - prefix_len - 2U;
    return 1;
}

static const char *rducks_find_top_level_char_len(const char *x, size_t len, char target) {
    int angle = 0;
    int square = 0;
    for (size_t i = 0; i < len; i++) {
        if (x[i] == '<') angle++;
        else if (x[i] == '>') { if (angle > 0) angle--; }
        else if (x[i] == '[') square++;
        else if (x[i] == ']') { if (square > 0) square--; }
        else if (x[i] == target && angle == 0 && square == 0) return x + i;
    }
    return NULL;
}

static const char *rducks_find_array_suffix(const char *x) {
    size_t len = strlen(x);
    int angle = 0;
    if (len < 2 || x[len - 1U] != ']') return NULL;
    for (size_t i = len; i > 0; --i) {
        char ch = x[i - 1U];
        if (ch == '>') angle++;
        else if (ch == '<') { if (angle > 0) angle--; }
        else if (ch == '[' && angle == 0) return x + i - 1U;
    }
    return NULL;
}

static void rducks_type_desc_destroy(rducks_type_desc_t *desc) {
    if (!desc) return;
    rducks_type_desc_destroy(desc->child);
    rducks_type_desc_destroy(desc->key);
    rducks_type_desc_destroy(desc->value);
    if (desc->field_names) {
        for (size_t i = 0; i < desc->field_count; i++) free(desc->field_names[i]);
        free(desc->field_names);
    }
    if (desc->field_types) {
        for (size_t i = 0; i < desc->field_count; i++) rducks_type_desc_destroy(desc->field_types[i]);
        free(desc->field_types);
    }
    free(desc);
}

static rducks_type_desc_t *rducks_type_desc_new(rducks_type_kind_t kind) {
    rducks_type_desc_t *desc = (rducks_type_desc_t *)calloc(1, sizeof(rducks_type_desc_t));
    if (desc) desc->kind = kind;
    return desc;
}

static int rducks_parse_type_desc_text(const char *text, rducks_type_desc_t **out, char *err, size_t err_cap);

static int rducks_parse_type_desc_len(const char *text, size_t len, rducks_type_desc_t **out, char *err, size_t err_cap) {
    char *copy = rducks_strdup_trimmed_len(text, len);
    int ok;
    if (!copy) {
        snprintf(err, err_cap, "out of memory");
        return 0;
    }
    ok = rducks_parse_type_desc_text(copy, out, err, err_cap);
    free(copy);
    return ok;
}

static int rducks_parse_type_desc_text(const char *text, rducks_type_desc_t **out, char *err, size_t err_cap) {
    const char *inner = NULL;
    size_t inner_len = 0;
    const char *suffix;
    rducks_type_desc_t *desc = NULL;
    if (!text || !out) return 0;
    *out = NULL;

    if (rducks_is_wrapped_by_angle(text, "decimal", &inner, &inner_len)) {
        const char *sep = rducks_find_top_level_char_len(inner, inner_len, ';');
        char *width_text = NULL;
        char *scale_text = NULL;
        char *endp = NULL;
        long width;
        long scale;
        if (!sep) sep = rducks_find_top_level_char_len(inner, inner_len, ',');
        if (!sep) {
            snprintf(err, err_cap, "decimal type must be decimal<width;scale>");
            return 0;
        }
        width_text = rducks_strdup_trimmed_len(inner, (size_t)(sep - inner));
        scale_text = rducks_strdup_trimmed_len(sep + 1, inner_len - (size_t)(sep - inner) - 1U);
        if (!width_text || !scale_text) {
            free(width_text);
            free(scale_text);
            goto oom;
        }
        width = strtol(width_text, &endp, 10);
        if (!endp || *endp != '\0') {
            free(width_text);
            free(scale_text);
            snprintf(err, err_cap, "invalid decimal width");
            return 0;
        }
        scale = strtol(scale_text, &endp, 10);
        if (!endp || *endp != '\0') {
            free(width_text);
            free(scale_text);
            snprintf(err, err_cap, "invalid decimal scale");
            return 0;
        }
        free(width_text);
        free(scale_text);
        if (width < 1 || width > 38 || scale < 0 || scale > width) {
            snprintf(err, err_cap, "invalid decimal width or scale");
            return 0;
        }
        desc = rducks_type_desc_new(RDUCKS_KIND_DECIMAL);
        if (!desc) goto oom;
        desc->decimal_width = (uint8_t)width;
        desc->decimal_scale = (uint8_t)scale;
        *out = desc;
        return 1;
    }
    if (rducks_is_wrapped_by_angle(text, "enum", &inner, &inner_len)) {
        size_t count = 0, cap = 0;
        const char *cursor = inner;
        size_t remain = inner_len;
        desc = rducks_type_desc_new(RDUCKS_KIND_ENUM);
        if (!desc) goto oom;
        while (remain > 0) {
            const char *sep = memchr(cursor, '|', remain);
            size_t part_len = sep ? (size_t)(sep - cursor) : remain;
            char *level;
            if (count == cap) {
                size_t new_cap = cap == 0 ? 4U : cap * 2U;
                char **new_names;
                if (new_cap <= cap) goto oom;
                new_names = (char **)realloc(desc->field_names, sizeof(char *) * new_cap);
                if (!new_names) goto oom;
                desc->field_names = new_names;
                for (size_t j = cap; j < new_cap; j++) desc->field_names[j] = NULL;
                cap = new_cap;
            }
            level = rducks_strdup_trimmed_len(cursor, part_len);
            if (!level) goto oom;
            if (!level[0]) {
                free(level);
                snprintf(err, err_cap, "enum levels must be non-empty");
                goto fail;
            }
            desc->field_names[count++] = level;
            desc->field_count = count;
            if (!sep) break;
            cursor = sep + 1;
            remain = inner_len - (size_t)(cursor - inner);
        }
        if (desc->field_count == 0) {
            snprintf(err, err_cap, "enum type must contain at least one level");
            goto fail;
        }
        *out = desc;
        return 1;
    }
    if (rducks_is_wrapped_by_angle(text, "union", &inner, &inner_len)) {
        size_t count = 0, cap = 0;
        const char *cursor = inner;
        size_t remain = inner_len;
        desc = rducks_type_desc_new(RDUCKS_KIND_UNION);
        if (!desc) goto oom;
        while (remain > 0) {
            const char *sep = rducks_find_top_level_char_len(cursor, remain, ';');
            size_t part_len = sep ? (size_t)(sep - cursor) : remain;
            const char *colon = rducks_find_top_level_char_len(cursor, part_len, ':');
            if (!colon) {
                snprintf(err, err_cap, "union members must be name:type");
                goto fail;
            }
            if (count == cap) {
                size_t new_cap = cap == 0 ? 4U : cap * 2U;
                char **new_names;
                rducks_type_desc_t **new_types;
                if (new_cap <= cap) goto oom;
                new_names = (char **)realloc(desc->field_names, sizeof(char *) * new_cap);
                if (!new_names) goto oom;
                desc->field_names = new_names;
                new_types = (rducks_type_desc_t **)realloc(desc->field_types, sizeof(rducks_type_desc_t *) * new_cap);
                if (!new_types) goto oom;
                desc->field_types = new_types;
                for (size_t j = cap; j < new_cap; j++) {
                    desc->field_names[j] = NULL;
                    desc->field_types[j] = NULL;
                }
                cap = new_cap;
            }
            desc->field_names[count] = rducks_strdup_trimmed_len(cursor, (size_t)(colon - cursor));
            if (!desc->field_names[count]) goto oom;
            if (!rducks_parse_type_desc_len(colon + 1, part_len - (size_t)(colon - cursor) - 1U,
                                            &desc->field_types[count], err, err_cap)) goto fail;
            count++;
            desc->field_count = count;
            if (!sep) break;
            cursor = sep + 1;
            remain = inner_len - (size_t)(cursor - inner);
        }
        if (desc->field_count == 0 || desc->field_count > 255U) {
            snprintf(err, err_cap, "union type must contain 1 to 255 members");
            goto fail;
        }
        *out = desc;
        return 1;
    }

    if (rducks_is_wrapped_by_angle(text, "list", &inner, &inner_len)) {
        desc = rducks_type_desc_new(RDUCKS_KIND_LIST);
        if (!desc || !rducks_parse_type_desc_len(inner, inner_len, &desc->child, err, err_cap)) goto fail;
        *out = desc;
        return 1;
    }
    if (rducks_is_wrapped_by_angle(text, "map", &inner, &inner_len)) {
        const char *sep = rducks_find_top_level_char_len(inner, inner_len, ';');
        if (!sep) sep = rducks_find_top_level_char_len(inner, inner_len, ',');
        if (!sep) {
            snprintf(err, err_cap, "map type must be map<key;value>");
            return 0;
        }
        desc = rducks_type_desc_new(RDUCKS_KIND_MAP);
        if (!desc || !rducks_parse_type_desc_len(inner, (size_t)(sep - inner), &desc->key, err, err_cap) ||
            !rducks_parse_type_desc_len(sep + 1, inner_len - (size_t)(sep - inner) - 1U, &desc->value, err, err_cap)) goto fail;
        *out = desc;
        return 1;
    }
    if (rducks_is_wrapped_by_angle(text, "struct", &inner, &inner_len)) {
        size_t count = 0, cap = 0;
        const char *cursor = inner;
        size_t remain = inner_len;
        desc = rducks_type_desc_new(RDUCKS_KIND_STRUCT);
        if (!desc) goto oom;
        while (remain > 0) {
            const char *sep = rducks_find_top_level_char_len(cursor, remain, ';');
            size_t part_len = sep ? (size_t)(sep - cursor) : remain;
            const char *colon = rducks_find_top_level_char_len(cursor, part_len, ':');
            if (!colon) {
                snprintf(err, err_cap, "struct fields must be name:type");
                goto fail;
            }
            if (count == cap) {
                size_t new_cap = cap == 0 ? 4U : cap * 2U;
                char **new_names;
                rducks_type_desc_t **new_types;
                if (new_cap <= cap) goto oom;
                new_names = (char **)realloc(desc->field_names, sizeof(char *) * new_cap);
                if (!new_names) goto oom;
                desc->field_names = new_names;
                new_types = (rducks_type_desc_t **)realloc(desc->field_types, sizeof(rducks_type_desc_t *) * new_cap);
                if (!new_types) goto oom;
                desc->field_types = new_types;
                for (size_t j = cap; j < new_cap; j++) {
                    desc->field_names[j] = NULL;
                    desc->field_types[j] = NULL;
                }
                cap = new_cap;
            }
            desc->field_names[count] = rducks_strdup_trimmed_len(cursor, (size_t)(colon - cursor));
            if (!desc->field_names[count]) goto oom;
            if (!rducks_parse_type_desc_len(colon + 1, part_len - (size_t)(colon - cursor) - 1U, &desc->field_types[count], err, err_cap)) goto fail;
            count++;
            desc->field_count = count;
            if (!sep) break;
            cursor = sep + 1;
            remain = inner_len - (size_t)(cursor - inner);
        }
        if (desc->field_count == 0) {
            snprintf(err, err_cap, "struct type must contain at least one field");
            goto fail;
        }
        *out = desc;
        return 1;
    }
    suffix = rducks_find_array_suffix(text);
    if (suffix) {
        size_t prefix_len = (size_t)(suffix - text);
        size_t len = strlen(text);
        size_t bracket_len = len - prefix_len - 2U;
        desc = rducks_type_desc_new(bracket_len == 0 ? RDUCKS_KIND_LIST : RDUCKS_KIND_ARRAY);
        if (!desc || !rducks_parse_type_desc_len(text, prefix_len, &desc->child, err, err_cap)) goto fail;
        if (bracket_len > 0) {
            char *ntext = rducks_strdup_len(suffix + 1, bracket_len);
            char *endp = NULL;
            unsigned long long nval;
            if (!ntext) goto oom;
            nval = strtoull(ntext, &endp, 10);
            if (!endp || *endp != '\0' || nval == 0 || nval > (unsigned long long)UINT64_MAX) {
                free(ntext);
                snprintf(err, err_cap, "invalid array size");
                goto fail;
            }
            desc->array_size = (idx_t)nval;
            free(ntext);
        }
        *out = desc;
        return 1;
    }
    {
        rducks_type_id_t scalar = rducks_type_from_token(text);
        if (scalar == RDUCKS_TYPE_INVALID) {
            snprintf(err, err_cap, "unsupported Rducks type: %s", text);
            return 0;
        }
        desc = rducks_type_desc_new(RDUCKS_KIND_SCALAR);
        if (!desc) goto oom;
        desc->scalar = scalar;
        *out = desc;
        return 1;
    }

oom:
    snprintf(err, err_cap, "out of memory");
fail:
    rducks_type_desc_destroy(desc);
    return 0;
}

static duckdb_logical_type rducks_create_logical_type_for_desc(const rducks_type_desc_t *desc) {
    if (!desc) return NULL;
    if (desc->kind == RDUCKS_KIND_SCALAR) return rducks_create_logical_type_for_id(desc->scalar);
    if (desc->kind == RDUCKS_KIND_LIST) {
        duckdb_logical_type child = rducks_create_logical_type_for_desc(desc->child);
        duckdb_logical_type out;
        if (!child) return NULL;
        out = duckdb_create_list_type(child);
        duckdb_destroy_logical_type(&child);
        return out;
    }
    if (desc->kind == RDUCKS_KIND_ARRAY) {
        duckdb_logical_type child = rducks_create_logical_type_for_desc(desc->child);
        duckdb_logical_type out;
        if (!child || desc->array_size == 0) return NULL;
        out = duckdb_create_array_type(child, desc->array_size);
        duckdb_destroy_logical_type(&child);
        return out;
    }
    if (desc->kind == RDUCKS_KIND_MAP) {
        duckdb_logical_type key = rducks_create_logical_type_for_desc(desc->key);
        duckdb_logical_type value = rducks_create_logical_type_for_desc(desc->value);
        duckdb_logical_type out = NULL;
        if (key && value) out = duckdb_create_map_type(key, value);
        if (key) duckdb_destroy_logical_type(&key);
        if (value) duckdb_destroy_logical_type(&value);
        return out;
    }
    if (desc->kind == RDUCKS_KIND_STRUCT) {
        duckdb_logical_type *types;
        duckdb_logical_type out = NULL;
        if (desc->field_count == 0 || desc->field_count > (SIZE_MAX / sizeof(duckdb_logical_type))) return NULL;
        types = (duckdb_logical_type *)calloc(desc->field_count, sizeof(duckdb_logical_type));
        if (!types) return NULL;
        for (size_t i = 0; i < desc->field_count; i++) {
            types[i] = rducks_create_logical_type_for_desc(desc->field_types[i]);
            if (!types[i]) goto cleanup_struct;
        }
        out = duckdb_create_struct_type(types, (const char **)desc->field_names, (idx_t)desc->field_count);
cleanup_struct:
        for (size_t i = 0; i < desc->field_count; i++) if (types[i]) duckdb_destroy_logical_type(&types[i]);
        free(types);
        return out;
    }
    if (desc->kind == RDUCKS_KIND_DECIMAL) {
        return duckdb_create_decimal_type(desc->decimal_width, desc->decimal_scale);
    }
    if (desc->kind == RDUCKS_KIND_ENUM) {
        if (desc->field_count == 0) return NULL;
        return duckdb_create_enum_type((const char **)desc->field_names, (idx_t)desc->field_count);
    }
    if (desc->kind == RDUCKS_KIND_UNION) {
        duckdb_logical_type *types;
        duckdb_logical_type out = NULL;
        if (desc->field_count == 0 || desc->field_count > 255U || desc->field_count > (SIZE_MAX / sizeof(duckdb_logical_type))) return NULL;
        types = (duckdb_logical_type *)calloc(desc->field_count, sizeof(duckdb_logical_type));
        if (!types) return NULL;
        for (size_t i = 0; i < desc->field_count; i++) {
            types[i] = rducks_create_logical_type_for_desc(desc->field_types[i]);
            if (!types[i]) goto cleanup_union;
        }
        out = duckdb_create_union_type(types, (const char **)desc->field_names, (idx_t)desc->field_count);
cleanup_union:
        for (size_t i = 0; i < desc->field_count; i++) if (types[i]) duckdb_destroy_logical_type(&types[i]);
        free(types);
        return out;
    }
    return NULL;
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

static int rducks_parse_type_list(const char *text, rducks_type_desc_t ***out, size_t *out_count, char *err, size_t err_cap) {
    char *copy;
    char *cursor;
    rducks_type_desc_t **items = NULL;
    size_t count = 0;
    size_t capacity = 0;
    if (!text || !out || !out_count) {
        snprintf(err, err_cap, "invalid type list");
        return 0;
    }
    *out = NULL;
    *out_count = 0;
    if (text[0] == '\0') return 1;
    copy = (char *)malloc(strlen(text) + 1U);
    if (!copy) {
        snprintf(err, err_cap, "out of memory");
        return 0;
    }
    strcpy(copy, text);
    cursor = copy;
    while (cursor && *cursor) {
        char *next;
        size_t part_len;
        rducks_type_desc_t *desc = NULL;
        next = (char *)rducks_find_top_level_char_len(cursor, strlen(cursor), ',');
        if (next) {
            *next = '\0';
            next++;
        }
        part_len = strlen(cursor);
        if (!rducks_parse_type_desc_len(cursor, part_len, &desc, err, err_cap)) {
            for (size_t i = 0; i < count; i++) rducks_type_desc_destroy(items[i]);
            free(items);
            free(copy);
            return 0;
        }
        if (count == capacity) {
            size_t new_capacity = capacity == 0U ? 4U : capacity * 2U;
            rducks_type_desc_t **new_items;
            if (new_capacity <= capacity || new_capacity > (SIZE_MAX / sizeof(rducks_type_desc_t *))) {
                snprintf(err, err_cap, "UDF argument list is too large to allocate");
                rducks_type_desc_destroy(desc);
                for (size_t i = 0; i < count; i++) rducks_type_desc_destroy(items[i]);
                free(items);
                free(copy);
                return 0;
            }
            new_items = (rducks_type_desc_t **)realloc(items, sizeof(rducks_type_desc_t *) * new_capacity);
            if (!new_items) {
                snprintf(err, err_cap, "out of memory");
                rducks_type_desc_destroy(desc);
                for (size_t i = 0; i < count; i++) rducks_type_desc_destroy(items[i]);
                free(items);
                free(copy);
                return 0;
            }
            items = new_items;
            capacity = new_capacity;
        }
        items[count++] = desc;
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
    if (meta->fun && meta->fun != R_NilValue) {
        R_ReleaseObject(meta->fun);
    }
    if (meta->compiled && meta->compiled != R_NilValue) {
        R_ReleaseObject(meta->compiled);
    }
    if (meta->args) {
        for (size_t i = 0; i < meta->arity; i++) rducks_type_desc_destroy(meta->args[i]);
    }
    free(meta->args);
    free(meta->arg_sizes);
    rducks_type_desc_destroy(meta->return_desc);
    free(meta);
}

static void rducks_inactive_scalar_meta_destroy(void *ptr) {
    rducks_inactive_scalar_meta_t *meta = (rducks_inactive_scalar_meta_t *)ptr;
    if (!meta) return;
    free(meta->name);
    free(meta);
}

static void rducks_inactive_scalar_udf(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    (void)input;
    (void)output;
    rducks_inactive_scalar_meta_t *meta =
        (rducks_inactive_scalar_meta_t *)duckdb_scalar_function_get_extra_info(info);
    char err[256];
    if (meta && meta->name) {
        snprintf(err, sizeof(err), "Rducks UDF %s has been unregistered", meta->name);
    } else {
        snprintf(err, sizeof(err), "Rducks UDF has been unregistered");
    }
    duckdb_scalar_function_set_error(info, err);
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

static SEXP rducks_build_string_class_vector(const char *klass, R_xlen_t len) {
    SEXP out = PROTECT(Rf_allocVector(STRSXP, len));
    rducks_set_class2(out, klass, "character");
    UNPROTECT(1);
    return out;
}

static SEXP rducks_build_hugeint_vector_sexp(duckdb_vector vector, idx_t offset, idx_t len, int is_unsigned, int is_uuid) {
    uint64_t *validity = duckdb_vector_get_validity(vector);
    uint8_t *data = (uint8_t *)duckdb_vector_get_data(vector);
    SEXP out = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)len));
    for (idx_t i = 0; i < len; i++) {
        idx_t row = offset + i;
        char buf[80];
        if (validity && !duckdb_validity_row_is_valid(validity, row)) {
            SET_STRING_ELT(out, (R_xlen_t)i, NA_STRING);
        } else if (is_uuid) {
            rducks_uuid_to_string(((duckdb_hugeint *)data)[row], buf);
            SET_STRING_ELT(out, (R_xlen_t)i, Rf_mkCharCE(buf, CE_UTF8));
        } else if (is_unsigned) {
            rducks_uhugeint_to_string(((duckdb_uhugeint *)data)[row], buf);
            SET_STRING_ELT(out, (R_xlen_t)i, Rf_mkCharCE(buf, CE_UTF8));
        } else {
            rducks_hugeint_to_string(((duckdb_hugeint *)data)[row], buf);
            SET_STRING_ELT(out, (R_xlen_t)i, Rf_mkCharCE(buf, CE_UTF8));
        }
    }
    rducks_set_class2(out, is_uuid ? "rducks_uuid" : (is_unsigned ? "rducks_uhugeint" : "rducks_hugeint"), "character");
    UNPROTECT(1);
    return out;
}

static SEXP rducks_build_interval_vector_sexp(duckdb_vector vector, idx_t offset, idx_t len) {
    uint64_t *validity = duckdb_vector_get_validity(vector);
    duckdb_interval *data = (duckdb_interval *)duckdb_vector_get_data(vector);
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 3));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 3));
    SEXP months = PROTECT(Rf_allocVector(INTSXP, (R_xlen_t)len));
    SEXP days = PROTECT(Rf_allocVector(INTSXP, (R_xlen_t)len));
    SEXP micros = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)len));
    for (idx_t i = 0; i < len; i++) {
        idx_t row = offset + i;
        char buf[80];
        if (validity && !duckdb_validity_row_is_valid(validity, row)) {
            INTEGER(months)[i] = NA_INTEGER;
            INTEGER(days)[i] = NA_INTEGER;
            SET_STRING_ELT(micros, (R_xlen_t)i, NA_STRING);
        } else {
            duckdb_hugeint h = rducks_hugeint_from_i128((__int128)data[row].micros);
            INTEGER(months)[i] = data[row].months;
            INTEGER(days)[i] = data[row].days;
            rducks_hugeint_to_string(h, buf);
            SET_STRING_ELT(micros, (R_xlen_t)i, Rf_mkCharCE(buf, CE_UTF8));
        }
    }
    SET_STRING_ELT(names, 0, Rf_mkChar("months"));
    SET_STRING_ELT(names, 1, Rf_mkChar("days"));
    SET_STRING_ELT(names, 2, Rf_mkChar("micros"));
    SET_VECTOR_ELT(out, 0, months);
    SET_VECTOR_ELT(out, 1, days);
    SET_VECTOR_ELT(out, 2, micros);
    Rf_setAttrib(out, R_NamesSymbol, names);
    rducks_set_class1(out, "rducks_interval");
    UNPROTECT(5);
    return out;
}

static SEXP rducks_build_decimal_sexp(const rducks_type_desc_t *desc, duckdb_vector vector, idx_t row) {
    void *data = duckdb_vector_get_data(vector);
    duckdb_hugeint scaled = rducks_decimal_storage_read(desc->decimal_width, data, row);
    char buf[96];
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 3));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 3));
    SEXP value = PROTECT(Rf_allocVector(STRSXP, 1));
    rducks_decimal_to_string(scaled, desc->decimal_scale, buf);
    SET_STRING_ELT(value, 0, Rf_mkCharCE(buf, CE_UTF8));
    SET_STRING_ELT(names, 0, Rf_mkChar("value"));
    SET_STRING_ELT(names, 1, Rf_mkChar("width"));
    SET_STRING_ELT(names, 2, Rf_mkChar("scale"));
    SET_VECTOR_ELT(out, 0, value);
    SET_VECTOR_ELT(out, 1, Rf_ScalarInteger(desc->decimal_width));
    SET_VECTOR_ELT(out, 2, Rf_ScalarInteger(desc->decimal_scale));
    Rf_setAttrib(out, R_NamesSymbol, names);
    rducks_set_class1(out, "rducks_decimal");
    UNPROTECT(3);
    return out;
}

static SEXP rducks_build_bits_sexp(duckdb_vector vector, idx_t row) {
    duckdb_string_t *strings = (duckdb_string_t *)duckdb_vector_get_data(vector);
    uint32_t size = duckdb_string_t_length(strings[row]);
    const uint8_t *bytes = (const uint8_t *)duckdb_string_t_data(&strings[row]);
    uint8_t padding = size > 0 ? bytes[0] : 0;
    R_xlen_t bit_len = size > 0 ? (R_xlen_t)((size - 1U) * 8U - padding) : 0;
    R_xlen_t raw_len = (bit_len + 7) / 8;
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 2));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 2));
    SEXP data = PROTECT(Rf_allocVector(RAWSXP, raw_len));
    if (raw_len > 0) memset(RAW(data), 0, (size_t)raw_len);
    for (R_xlen_t j = 0; j < bit_len; j++) {
        R_xlen_t src_pos = j + padding;
        uint8_t bit = (bytes[1 + src_pos / 8] & (uint8_t)(1U << (7 - (src_pos % 8)))) ? 1U : 0U;
        if (bit) RAW(data)[j / 8] = (Rbyte)(RAW(data)[j / 8] | (uint8_t)(1U << (7 - (j % 8))));
    }
    SET_STRING_ELT(names, 0, Rf_mkChar("data"));
    SET_STRING_ELT(names, 1, Rf_mkChar("length"));
    SET_VECTOR_ELT(out, 0, data);
    SET_VECTOR_ELT(out, 1, Rf_ScalarInteger((int)bit_len));
    Rf_setAttrib(out, R_NamesSymbol, names);
    rducks_set_class1(out, "rducks_bits");
    UNPROTECT(3);
    return out;
}

static SEXP rducks_build_enum_sexp(const rducks_type_desc_t *desc, duckdb_vector vector, idx_t row) {
    void *data = duckdb_vector_get_data(vector);
    uint32_t code = 0;
    SEXP out = PROTECT(Rf_allocVector(INTSXP, 1));
    SEXP levels = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)desc->field_count));
    if (desc->field_count <= 255U) code = ((uint8_t *)data)[row];
    else if (desc->field_count <= 65535U) code = ((uint16_t *)data)[row];
    else code = ((uint32_t *)data)[row];
    INTEGER(out)[0] = (int)code + 1;
    for (size_t i = 0; i < desc->field_count; i++) SET_STRING_ELT(levels, (R_xlen_t)i, Rf_mkCharCE(desc->field_names[i], CE_UTF8));
    Rf_setAttrib(out, R_LevelsSymbol, levels);
    rducks_set_class2(out, "rducks_enum", "factor");
    UNPROTECT(2);
    return out;
}

static SEXP rducks_build_scalar_sexp(rducks_type_id_t type, duckdb_vector vector, idx_t row) {
    uint64_t *validity = duckdb_vector_get_validity(vector);
    uint8_t *data = (uint8_t *)duckdb_vector_get_data(vector);
    if (validity && !duckdb_validity_row_is_valid(validity, row)) {
        switch (type) {
        case RDUCKS_TYPE_BOOL:
            return Rf_ScalarLogical(NA_LOGICAL);
        case RDUCKS_TYPE_I8:
        case RDUCKS_TYPE_U8:
        case RDUCKS_TYPE_I16:
        case RDUCKS_TYPE_U16:
        case RDUCKS_TYPE_I32:
            return Rf_ScalarInteger(NA_INTEGER);
        case RDUCKS_TYPE_VARCHAR:
            return Rf_ScalarString(NA_STRING);
        case RDUCKS_TYPE_I64:
        case RDUCKS_TYPE_U64:
        case RDUCKS_TYPE_HUGEINT:
        case RDUCKS_TYPE_UHUGEINT:
        case RDUCKS_TYPE_UUID: {
            const char *klass = type == RDUCKS_TYPE_I64 ? "rducks_bigint" :
                                type == RDUCKS_TYPE_U64 ? "rducks_ubigint" :
                                type == RDUCKS_TYPE_HUGEINT ? "rducks_hugeint" :
                                type == RDUCKS_TYPE_UHUGEINT ? "rducks_uhugeint" : "rducks_uuid";
            SEXP out = PROTECT(Rf_allocVector(STRSXP, 1));
            SET_STRING_ELT(out, 0, NA_STRING);
            rducks_set_class2(out, klass, "character");
            UNPROTECT(1);
            return out;
        }
        case RDUCKS_TYPE_INTERVAL:
            return rducks_build_interval_vector_sexp(vector, row, 1);
        case RDUCKS_TYPE_BIT:
            return R_NilValue;
        default:
            return Rf_ScalarReal(NA_REAL);
        }
    }
    switch (type) {
    case RDUCKS_TYPE_BOOL:
        return Rf_ScalarLogical(((bool *)data)[row] ? TRUE : FALSE);
    case RDUCKS_TYPE_I8:
        return Rf_ScalarInteger((int)((int8_t *)data)[row]);
    case RDUCKS_TYPE_U8:
        return Rf_ScalarInteger((int)((uint8_t *)data)[row]);
    case RDUCKS_TYPE_I16:
        return Rf_ScalarInteger((int)((int16_t *)data)[row]);
    case RDUCKS_TYPE_U16:
        return Rf_ScalarInteger((int)((uint16_t *)data)[row]);
    case RDUCKS_TYPE_I32:
        return Rf_ScalarInteger((int)((int32_t *)data)[row]);
    case RDUCKS_TYPE_U32:
        return Rf_ScalarReal((double)((uint32_t *)data)[row]);
    case RDUCKS_TYPE_F32:
        return Rf_ScalarReal((double)((float *)data)[row]);
    case RDUCKS_TYPE_F64:
        return Rf_ScalarReal(((double *)data)[row]);
    case RDUCKS_TYPE_VARCHAR: {
        duckdb_string_t *strings = (duckdb_string_t *)data;
        uint32_t len = duckdb_string_t_length(strings[row]);
        const char *str = duckdb_string_t_data(&strings[row]);
        return Rf_ScalarString(Rf_mkCharLenCE(str, (int)len, CE_UTF8));
    }
    case RDUCKS_TYPE_BLOB: {
        duckdb_string_t *strings = (duckdb_string_t *)data;
        uint32_t len = duckdb_string_t_length(strings[row]);
        const char *bytes = duckdb_string_t_data(&strings[row]);
        SEXP out = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)len));
        if (len > 0) memcpy(RAW(out), bytes, (size_t)len);
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_DATE: {
        duckdb_date *dates = (duckdb_date *)data;
        SEXP out = PROTECT(Rf_ScalarReal((double)dates[row].days));
        SEXP cls = PROTECT(Rf_mkString("Date"));
        Rf_classgets(out, cls);
        UNPROTECT(2);
        return out;
    }
    case RDUCKS_TYPE_TIME: {
        duckdb_time *times = (duckdb_time *)data;
        return Rf_ScalarReal((double)times[row].micros / 1000000.0);
    }
    case RDUCKS_TYPE_TIMESTAMP: {
        duckdb_timestamp *timestamps = (duckdb_timestamp *)data;
        SEXP out = PROTECT(Rf_ScalarReal((double)timestamps[row].micros / 1000000.0));
        SEXP cls = PROTECT(Rf_allocVector(STRSXP, 2));
        SET_STRING_ELT(cls, 0, Rf_mkChar("POSIXct"));
        SET_STRING_ELT(cls, 1, Rf_mkChar("POSIXt"));
        Rf_classgets(out, cls);
        UNPROTECT(2);
        return out;
    }
    case RDUCKS_TYPE_I64: {
        char buf[80];
        SEXP out = PROTECT(Rf_allocVector(STRSXP, 1));
        rducks_hugeint_to_string(rducks_hugeint_from_i128((__int128)((int64_t *)data)[row]), buf);
        SET_STRING_ELT(out, 0, Rf_mkCharCE(buf, CE_UTF8));
        rducks_set_class2(out, "rducks_bigint", "character");
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_U64: {
        char buf[80];
        duckdb_uhugeint value;
        SEXP out = PROTECT(Rf_allocVector(STRSXP, 1));
        value.lower = ((uint64_t *)data)[row];
        value.upper = 0;
        rducks_uhugeint_to_string(value, buf);
        SET_STRING_ELT(out, 0, Rf_mkCharCE(buf, CE_UTF8));
        rducks_set_class2(out, "rducks_ubigint", "character");
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_HUGEINT:
        return rducks_build_hugeint_vector_sexp(vector, row, 1, 0, 0);
    case RDUCKS_TYPE_UHUGEINT:
        return rducks_build_hugeint_vector_sexp(vector, row, 1, 1, 0);
    case RDUCKS_TYPE_UUID:
        return rducks_build_hugeint_vector_sexp(vector, row, 1, 0, 1);
    case RDUCKS_TYPE_INTERVAL:
        return rducks_build_interval_vector_sexp(vector, row, 1);
    case RDUCKS_TYPE_BIT:
        return rducks_build_bits_sexp(vector, row);
    default:
        return R_NilValue;
    }
}

static SEXP rducks_build_sexp_from_desc(const rducks_type_desc_t *desc, duckdb_vector vector, idx_t row);

static int rducks_scalar_can_atomic_vector(rducks_type_id_t type) {
    return type != RDUCKS_TYPE_BLOB && type != RDUCKS_TYPE_BIT;
}

static SEXP rducks_build_scalar_vector_sexp(rducks_type_id_t type, duckdb_vector vector, idx_t offset, idx_t len) {
    uint64_t *validity = duckdb_vector_get_validity(vector);
    uint8_t *data = (uint8_t *)duckdb_vector_get_data(vector);
    R_xlen_t r_len = (R_xlen_t)len;
    switch (type) {
    case RDUCKS_TYPE_BOOL: {
        SEXP out = PROTECT(Rf_allocVector(LGLSXP, r_len));
        for (idx_t i = 0; i < len; i++) {
            idx_t row = offset + i;
            LOGICAL(out)[i] = (validity && !duckdb_validity_row_is_valid(validity, row)) ? NA_LOGICAL :
                                                                                           (((bool *)data)[row] ? TRUE : FALSE);
        }
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_I8: {
        SEXP out = PROTECT(Rf_allocVector(INTSXP, r_len));
        for (idx_t i = 0; i < len; i++) {
            idx_t row = offset + i;
            INTEGER(out)[i] = (validity && !duckdb_validity_row_is_valid(validity, row)) ? NA_INTEGER :
                                                                                          (int)((int8_t *)data)[row];
        }
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_U8: {
        SEXP out = PROTECT(Rf_allocVector(INTSXP, r_len));
        for (idx_t i = 0; i < len; i++) {
            idx_t row = offset + i;
            INTEGER(out)[i] = (validity && !duckdb_validity_row_is_valid(validity, row)) ? NA_INTEGER :
                                                                                          (int)((uint8_t *)data)[row];
        }
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_I16: {
        SEXP out = PROTECT(Rf_allocVector(INTSXP, r_len));
        for (idx_t i = 0; i < len; i++) {
            idx_t row = offset + i;
            INTEGER(out)[i] = (validity && !duckdb_validity_row_is_valid(validity, row)) ? NA_INTEGER :
                                                                                          (int)((int16_t *)data)[row];
        }
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_U16: {
        SEXP out = PROTECT(Rf_allocVector(INTSXP, r_len));
        for (idx_t i = 0; i < len; i++) {
            idx_t row = offset + i;
            INTEGER(out)[i] = (validity && !duckdb_validity_row_is_valid(validity, row)) ? NA_INTEGER :
                                                                                          (int)((uint16_t *)data)[row];
        }
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_I32: {
        SEXP out = PROTECT(Rf_allocVector(INTSXP, r_len));
        for (idx_t i = 0; i < len; i++) {
            idx_t row = offset + i;
            INTEGER(out)[i] = (validity && !duckdb_validity_row_is_valid(validity, row)) ? NA_INTEGER :
                                                                                          (int)((int32_t *)data)[row];
        }
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_U32: {
        SEXP out = PROTECT(Rf_allocVector(REALSXP, r_len));
        for (idx_t i = 0; i < len; i++) {
            idx_t row = offset + i;
            REAL(out)[i] = (validity && !duckdb_validity_row_is_valid(validity, row)) ? NA_REAL :
                                                                                       (double)((uint32_t *)data)[row];
        }
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_F32: {
        SEXP out = PROTECT(Rf_allocVector(REALSXP, r_len));
        for (idx_t i = 0; i < len; i++) {
            idx_t row = offset + i;
            REAL(out)[i] = (validity && !duckdb_validity_row_is_valid(validity, row)) ? NA_REAL :
                                                                                       (double)((float *)data)[row];
        }
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_F64: {
        SEXP out = PROTECT(Rf_allocVector(REALSXP, r_len));
        for (idx_t i = 0; i < len; i++) {
            idx_t row = offset + i;
            REAL(out)[i] = (validity && !duckdb_validity_row_is_valid(validity, row)) ? NA_REAL : ((double *)data)[row];
        }
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_VARCHAR: {
        duckdb_string_t *strings = (duckdb_string_t *)data;
        SEXP out = PROTECT(Rf_allocVector(STRSXP, r_len));
        for (idx_t i = 0; i < len; i++) {
            idx_t row = offset + i;
            if (validity && !duckdb_validity_row_is_valid(validity, row)) {
                SET_STRING_ELT(out, i, NA_STRING);
            } else {
                uint32_t slen = duckdb_string_t_length(strings[row]);
                const char *str = duckdb_string_t_data(&strings[row]);
                SET_STRING_ELT(out, i, Rf_mkCharLenCE(str, (int)slen, CE_UTF8));
            }
        }
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_DATE: {
        duckdb_date *dates = (duckdb_date *)data;
        SEXP out = PROTECT(Rf_allocVector(REALSXP, r_len));
        SEXP cls = PROTECT(Rf_mkString("Date"));
        for (idx_t i = 0; i < len; i++) {
            idx_t row = offset + i;
            REAL(out)[i] = (validity && !duckdb_validity_row_is_valid(validity, row)) ? NA_REAL : (double)dates[row].days;
        }
        Rf_classgets(out, cls);
        UNPROTECT(2);
        return out;
    }
    case RDUCKS_TYPE_TIME: {
        duckdb_time *times = (duckdb_time *)data;
        SEXP out = PROTECT(Rf_allocVector(REALSXP, r_len));
        for (idx_t i = 0; i < len; i++) {
            idx_t row = offset + i;
            REAL(out)[i] = (validity && !duckdb_validity_row_is_valid(validity, row)) ? NA_REAL :
                                                                                       (double)times[row].micros / 1000000.0;
        }
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_TIMESTAMP: {
        duckdb_timestamp *timestamps = (duckdb_timestamp *)data;
        SEXP out = PROTECT(Rf_allocVector(REALSXP, r_len));
        SEXP cls = PROTECT(Rf_allocVector(STRSXP, 2));
        for (idx_t i = 0; i < len; i++) {
            idx_t row = offset + i;
            REAL(out)[i] = (validity && !duckdb_validity_row_is_valid(validity, row)) ? NA_REAL :
                                                                                       (double)timestamps[row].micros / 1000000.0;
        }
        SET_STRING_ELT(cls, 0, Rf_mkChar("POSIXct"));
        SET_STRING_ELT(cls, 1, Rf_mkChar("POSIXt"));
        Rf_classgets(out, cls);
        UNPROTECT(2);
        return out;
    }
    case RDUCKS_TYPE_I64: {
        SEXP out = PROTECT(Rf_allocVector(STRSXP, r_len));
        for (idx_t i = 0; i < len; i++) {
            idx_t row = offset + i;
            char buf[80];
            if (validity && !duckdb_validity_row_is_valid(validity, row)) SET_STRING_ELT(out, i, NA_STRING);
            else {
                rducks_hugeint_to_string(rducks_hugeint_from_i128((__int128)((int64_t *)data)[row]), buf);
                SET_STRING_ELT(out, i, Rf_mkCharCE(buf, CE_UTF8));
            }
        }
        rducks_set_class2(out, "rducks_bigint", "character");
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_U64: {
        SEXP out = PROTECT(Rf_allocVector(STRSXP, r_len));
        for (idx_t i = 0; i < len; i++) {
            idx_t row = offset + i;
            char buf[80];
            if (validity && !duckdb_validity_row_is_valid(validity, row)) SET_STRING_ELT(out, i, NA_STRING);
            else {
                duckdb_uhugeint value;
                value.lower = ((uint64_t *)data)[row];
                value.upper = 0;
                rducks_uhugeint_to_string(value, buf);
                SET_STRING_ELT(out, i, Rf_mkCharCE(buf, CE_UTF8));
            }
        }
        rducks_set_class2(out, "rducks_ubigint", "character");
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_HUGEINT:
        return rducks_build_hugeint_vector_sexp(vector, offset, len, 0, 0);
    case RDUCKS_TYPE_UHUGEINT:
        return rducks_build_hugeint_vector_sexp(vector, offset, len, 1, 0);
    case RDUCKS_TYPE_UUID:
        return rducks_build_hugeint_vector_sexp(vector, offset, len, 0, 1);
    case RDUCKS_TYPE_INTERVAL:
        return rducks_build_interval_vector_sexp(vector, offset, len);
    default:
        return R_NilValue;
    }
}

static SEXP rducks_build_sequence_sexp(const rducks_type_desc_t *desc, duckdb_vector vector, idx_t offset, idx_t len) {
    if (desc && desc->kind == RDUCKS_KIND_SCALAR && rducks_scalar_can_atomic_vector(desc->scalar)) {
        return rducks_build_scalar_vector_sexp(desc->scalar, vector, offset, len);
    }
    SEXP out = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)len));
    for (idx_t i = 0; i < len; i++) {
        SEXP elt = rducks_build_sexp_from_desc(desc, vector, offset + i);
        SET_VECTOR_ELT(out, (R_xlen_t)i, elt);
    }
    UNPROTECT(1);
    return out;
}

static SEXP rducks_build_sexp_from_desc(const rducks_type_desc_t *desc, duckdb_vector vector, idx_t row) {
    uint64_t *validity;
    if (!desc) return R_NilValue;
    validity = duckdb_vector_get_validity(vector);
    if (validity && !duckdb_validity_row_is_valid(validity, row)) return R_NilValue;
    if (desc->kind == RDUCKS_KIND_SCALAR) return rducks_build_scalar_sexp(desc->scalar, vector, row);
    if (desc->kind == RDUCKS_KIND_DECIMAL) return rducks_build_decimal_sexp(desc, vector, row);
    if (desc->kind == RDUCKS_KIND_ENUM) return rducks_build_enum_sexp(desc, vector, row);
    if (desc->kind == RDUCKS_KIND_UNION) {
        duckdb_vector tag_vec = duckdb_struct_vector_get_child(vector, 0);
        uint8_t *tags = (uint8_t *)duckdb_vector_get_data(tag_vec);
        uint8_t tag = tags[row];
        duckdb_vector member_vec;
        SEXP out;
        SEXP names;
        SEXP value;
        if ((size_t)tag >= desc->field_count) return R_NilValue;
        member_vec = duckdb_struct_vector_get_child(vector, (idx_t)tag + 1);
        out = PROTECT(Rf_allocVector(VECSXP, 2));
        names = PROTECT(Rf_allocVector(STRSXP, 2));
        value = PROTECT(rducks_build_sexp_from_desc(desc->field_types[tag], member_vec, row));
        SET_STRING_ELT(names, 0, Rf_mkChar("tag"));
        SET_STRING_ELT(names, 1, Rf_mkChar("value"));
        SET_VECTOR_ELT(out, 0, Rf_mkString(desc->field_names[tag]));
        SET_VECTOR_ELT(out, 1, value);
        Rf_setAttrib(out, R_NamesSymbol, names);
        rducks_set_class1(out, "rducks_union");
        UNPROTECT(3);
        return out;
    }
    if (desc->kind == RDUCKS_KIND_LIST) {
        duckdb_list_entry *entries = (duckdb_list_entry *)duckdb_vector_get_data(vector);
        duckdb_vector child = duckdb_list_vector_get_child(vector);
        idx_t len = (idx_t)entries[row].length;
        idx_t offset = (idx_t)entries[row].offset;
        return rducks_build_sequence_sexp(desc->child, child, offset, len);
    }
    if (desc->kind == RDUCKS_KIND_ARRAY) {
        duckdb_vector child = duckdb_array_vector_get_child(vector);
        idx_t len = desc->array_size;
        idx_t offset = row * len;
        return rducks_build_sequence_sexp(desc->child, child, offset, len);
    }
    if (desc->kind == RDUCKS_KIND_STRUCT) {
        SEXP out = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)desc->field_count));
        SEXP names = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)desc->field_count));
        for (size_t i = 0; i < desc->field_count; i++) {
            duckdb_vector child = duckdb_struct_vector_get_child(vector, (idx_t)i);
            SEXP elt = rducks_build_sexp_from_desc(desc->field_types[i], child, row);
            SET_VECTOR_ELT(out, (R_xlen_t)i, elt);
            SET_STRING_ELT(names, (R_xlen_t)i, Rf_mkChar(desc->field_names[i]));
        }
        Rf_setAttrib(out, R_NamesSymbol, names);
        UNPROTECT(2);
        return out;
    }
    if (desc->kind == RDUCKS_KIND_MAP) {
        duckdb_list_entry *entries = (duckdb_list_entry *)duckdb_vector_get_data(vector);
        duckdb_vector child = duckdb_list_vector_get_child(vector);
        duckdb_vector key_vec = duckdb_struct_vector_get_child(child, 0);
        duckdb_vector val_vec = duckdb_struct_vector_get_child(child, 1);
        idx_t len = (idx_t)entries[row].length;
        idx_t offset = (idx_t)entries[row].offset;
        SEXP out = PROTECT(Rf_allocVector(VECSXP, 2));
        SEXP names = PROTECT(Rf_allocVector(STRSXP, 2));
        SEXP keys = PROTECT(rducks_build_sequence_sexp(desc->key, key_vec, offset, len));
        SEXP values = PROTECT(rducks_build_sequence_sexp(desc->value, val_vec, offset, len));
        SET_STRING_ELT(names, 0, Rf_mkChar("keys"));
        SET_STRING_ELT(names, 1, Rf_mkChar("values"));
        SET_VECTOR_ELT(out, 0, keys);
        SET_VECTOR_ELT(out, 1, values);
        Rf_setAttrib(out, R_NamesSymbol, names);
        UNPROTECT(4);
        return out;
    }
    return R_NilValue;
}

static int rducks_prepare_arg(const rducks_type_desc_t *desc, duckdb_vector vector, idx_t row, bool *is_null,
                              void **arg_ptr, void **arg_alloc, int *arg_protect_count) {
    uint64_t *validity = duckdb_vector_get_validity(vector);
    uint8_t *data = (uint8_t *)duckdb_vector_get_data(vector);
    size_t size;
    *is_null = false;
    *arg_ptr = NULL;
    *arg_alloc = NULL;
    if (validity && !duckdb_validity_row_is_valid(validity, row)) {
        *is_null = true;
        if (desc && desc->kind != RDUCKS_KIND_SCALAR) {
            *arg_ptr = (void *)R_NilValue;
        }
        return 1;
    }
    if (!desc) return 0;
    if (desc->kind != RDUCKS_KIND_SCALAR || rducks_scalar_uses_sexp_bridge(desc->scalar)) {
        SEXP value = rducks_build_sexp_from_desc(desc, vector, row);
        PROTECT(value);
        (*arg_protect_count)++;
        *arg_ptr = (void *)value;
        return 1;
    }
    if (desc->scalar == RDUCKS_TYPE_VARCHAR) {
        duckdb_string_t *strings = (duckdb_string_t *)data;
        char *copy = rducks_copy_duckdb_string(&strings[row]);
        if (!copy) return 0;
        *arg_alloc = copy;
        *arg_ptr = (void *)arg_alloc;
        return 1;
    }
    if (desc->scalar == RDUCKS_TYPE_BLOB) {
        duckdb_string_t *strings = (duckdb_string_t *)data;
        rducks_blob_t *blob = (rducks_blob_t *)malloc(sizeof(rducks_blob_t));
        if (!blob) return 0;
        blob->len = (uint64_t)duckdb_string_t_length(strings[row]);
        blob->ptr = (const uint8_t *)duckdb_string_t_data(&strings[row]);
        *arg_alloc = blob;
        *arg_ptr = (void *)blob;
        return 1;
    }
    size = rducks_type_size(desc->scalar);
    if (size == 0U) return 0;
    *arg_ptr = (void *)(data + ((size_t)row * size));
    return 1;
}

static int rducks_sexp_is_null_scalar(SEXP value, R_xlen_t index) {
    if (value == R_NilValue || XLENGTH(value) <= index) return 1;
    switch (TYPEOF(value)) {
    case LGLSXP:
        return LOGICAL(value)[index] == NA_LOGICAL;
    case INTSXP:
        return INTEGER(value)[index] == NA_INTEGER;
    case REALSXP:
        return ISNA(REAL(value)[index]);
    case STRSXP:
        return STRING_ELT(value, index) == NA_STRING;
    default:
        return 0;
    }
}

static SEXP rducks_list_elt_by_name_or_pos(SEXP value, const char *name, R_xlen_t pos) {
    if (value == R_NilValue || TYPEOF(value) != VECSXP) return R_NilValue;
    SEXP names = Rf_getAttrib(value, R_NamesSymbol);
    if (names != R_NilValue && TYPEOF(names) == STRSXP) {
        for (R_xlen_t i = 0; i < XLENGTH(names) && i < XLENGTH(value); i++) {
            SEXP elt_name = STRING_ELT(names, i);
            if (elt_name != NA_STRING && strcmp(Rf_translateCharUTF8(elt_name), name) == 0) {
                return VECTOR_ELT(value, i);
            }
        }
    }
    if (pos < XLENGTH(value)) return VECTOR_ELT(value, pos);
    return R_NilValue;
}

static R_xlen_t rducks_sequence_length(SEXP value) {
    if (value == R_NilValue) return 0;
    if (Rf_inherits(value, "rducks_interval")) {
        SEXP months = rducks_list_elt_by_name_or_pos(value, "months", 0);
        return months == R_NilValue ? 0 : XLENGTH(months);
    }
    return XLENGTH(value);
}

static const char *rducks_string_at(SEXP value, R_xlen_t index) {
    if (value == R_NilValue) return NULL;
    if (TYPEOF(value) == STRSXP) {
        if (XLENGTH(value) <= index || STRING_ELT(value, index) == NA_STRING) return NULL;
        return Rf_translateCharUTF8(STRING_ELT(value, index));
    }
    if (Rf_inherits(value, "factor")) {
        SEXP levels = Rf_getAttrib(value, R_LevelsSymbol);
        int code;
        if (TYPEOF(value) != INTSXP || XLENGTH(value) <= index || INTEGER(value)[index] == NA_INTEGER) return NULL;
        code = INTEGER(value)[index];
        if (TYPEOF(levels) != STRSXP || code < 1 || code > XLENGTH(levels) || STRING_ELT(levels, code - 1) == NA_STRING) return NULL;
        return Rf_translateCharUTF8(STRING_ELT(levels, code - 1));
    }
    if (XLENGTH(value) <= index) return NULL;
    if (index != 0 || XLENGTH(value) != 1) return NULL;
    return Rf_translateCharUTF8(Rf_asChar(value));
}

static int rducks_write_value_to_vector(const rducks_type_desc_t *desc, duckdb_vector vector, idx_t row, SEXP value);

static int rducks_write_scalar_value_to_vector(rducks_type_id_t type, duckdb_vector vector, idx_t row, SEXP value,
                                               R_xlen_t index) {
    uint8_t *data;
    if (value == R_NilValue || XLENGTH(value) <= index || rducks_sexp_is_null_scalar(value, index)) {
        rducks_output_set_null(vector, row);
        return 1;
    }
    data = (uint8_t *)duckdb_vector_get_data(vector);
    switch (type) {
    case RDUCKS_TYPE_BOOL: {
        int v = TYPEOF(value) == LGLSXP ? LOGICAL(value)[index] : Rf_asLogical(value);
        if (v == NA_LOGICAL) rducks_output_set_null(vector, row);
        else {
            ((bool *)data)[row] = v == TRUE;
            rducks_output_set_valid(vector, row);
        }
        return 1;
    }
    case RDUCKS_TYPE_I8:
        ((int8_t *)data)[row] = (int8_t)(TYPEOF(value) == INTSXP ? INTEGER(value)[index] : Rf_asInteger(value));
        rducks_output_set_valid(vector, row);
        return 1;
    case RDUCKS_TYPE_U8:
        ((uint8_t *)data)[row] = (uint8_t)(TYPEOF(value) == INTSXP ? INTEGER(value)[index] : Rf_asInteger(value));
        rducks_output_set_valid(vector, row);
        return 1;
    case RDUCKS_TYPE_I16:
        ((int16_t *)data)[row] = (int16_t)(TYPEOF(value) == INTSXP ? INTEGER(value)[index] : Rf_asInteger(value));
        rducks_output_set_valid(vector, row);
        return 1;
    case RDUCKS_TYPE_U16:
        ((uint16_t *)data)[row] = (uint16_t)(TYPEOF(value) == INTSXP ? INTEGER(value)[index] : Rf_asInteger(value));
        rducks_output_set_valid(vector, row);
        return 1;
    case RDUCKS_TYPE_I32:
        ((int32_t *)data)[row] = (int32_t)(TYPEOF(value) == INTSXP ? INTEGER(value)[index] : Rf_asInteger(value));
        rducks_output_set_valid(vector, row);
        return 1;
    case RDUCKS_TYPE_U32:
        ((uint32_t *)data)[row] = (uint32_t)(TYPEOF(value) == REALSXP ? REAL(value)[index] : Rf_asReal(value));
        rducks_output_set_valid(vector, row);
        return 1;
    case RDUCKS_TYPE_F32:
        ((float *)data)[row] = (float)(TYPEOF(value) == REALSXP ? REAL(value)[index] : Rf_asReal(value));
        rducks_output_set_valid(vector, row);
        return 1;
    case RDUCKS_TYPE_F64:
        ((double *)data)[row] = (double)(TYPEOF(value) == REALSXP ? REAL(value)[index] : Rf_asReal(value));
        rducks_output_set_valid(vector, row);
        return 1;
    case RDUCKS_TYPE_VARCHAR: {
        SEXP str_vec = value;
        int protected = 0;
        if (TYPEOF(str_vec) != STRSXP) {
            str_vec = PROTECT(Rf_coerceVector(value, STRSXP));
            protected = 1;
            index = 0;
        }
        if (XLENGTH(str_vec) <= index || STRING_ELT(str_vec, index) == NA_STRING) {
            rducks_output_set_null(vector, row);
        } else {
            const char *str = Rf_translateCharUTF8(STRING_ELT(str_vec, index));
            duckdb_vector_assign_string_element(vector, row, str);
            rducks_output_set_valid(vector, row);
        }
        if (protected) UNPROTECT(1);
        return 1;
    }
    case RDUCKS_TYPE_BLOB:
        if (TYPEOF(value) != RAWSXP) return 0;
        duckdb_vector_assign_string_element_len(vector, row, (const char *)RAW(value), (idx_t)XLENGTH(value));
        rducks_output_set_valid(vector, row);
        return 1;
    case RDUCKS_TYPE_DATE: {
        double v = TYPEOF(value) == REALSXP ? REAL(value)[index] : Rf_asReal(value);
        ((duckdb_date *)data)[row].days = (int32_t)v;
        rducks_output_set_valid(vector, row);
        return 1;
    }
    case RDUCKS_TYPE_TIME: {
        double v = TYPEOF(value) == REALSXP ? REAL(value)[index] : Rf_asReal(value);
        int64_t micros;
        if (!R_FINITE(v) || v < 0.0 || v >= 86400.0) return 0;
        micros = rducks_round_double_to_i64(v * 1000000.0);
        if (micros < 0 || micros >= INT64_C(86400000000)) return 0;
        ((duckdb_time *)data)[row].micros = micros;
        rducks_output_set_valid(vector, row);
        return 1;
    }
    case RDUCKS_TYPE_TIMESTAMP: {
        double v = TYPEOF(value) == REALSXP ? REAL(value)[index] : Rf_asReal(value);
        if (!R_FINITE(v) || v < -9223372036854.774 || v > 9223372036854.774) return 0;
        ((duckdb_timestamp *)data)[row].micros = rducks_round_double_to_i64(v * 1000000.0);
        rducks_output_set_valid(vector, row);
        return 1;
    }
    case RDUCKS_TYPE_I64: {
        const char *text = rducks_string_at(value, index);
        duckdb_hugeint parsed;
        __int128 v;
        if (!text || !rducks_parse_hugeint_text(text, &parsed)) return 0;
        v = rducks_hugeint_to_i128(parsed);
        if (v < -(((__int128)1) << 63) || v > (((__int128)1) << 63) - 1) return 0;
        ((int64_t *)data)[row] = (int64_t)v;
        rducks_output_set_valid(vector, row);
        return 1;
    }
    case RDUCKS_TYPE_U64: {
        const char *text = rducks_string_at(value, index);
        duckdb_uhugeint parsed;
        unsigned __int128 v;
        if (!text || !rducks_parse_uhugeint_text(text, &parsed)) return 0;
        v = rducks_uhugeint_bits(parsed);
        if (v > UINT64_MAX) return 0;
        ((uint64_t *)data)[row] = (uint64_t)v;
        rducks_output_set_valid(vector, row);
        return 1;
    }
    case RDUCKS_TYPE_HUGEINT: {
        const char *text = rducks_string_at(value, index);
        duckdb_hugeint parsed;
        if (!text || !rducks_parse_hugeint_text(text, &parsed)) return 0;
        ((duckdb_hugeint *)data)[row] = parsed;
        rducks_output_set_valid(vector, row);
        return 1;
    }
    case RDUCKS_TYPE_UHUGEINT: {
        const char *text = rducks_string_at(value, index);
        duckdb_uhugeint parsed;
        if (!text || !rducks_parse_uhugeint_text(text, &parsed)) return 0;
        ((duckdb_uhugeint *)data)[row] = parsed;
        rducks_output_set_valid(vector, row);
        return 1;
    }
    case RDUCKS_TYPE_UUID: {
        const char *text = rducks_string_at(value, index);
        duckdb_hugeint parsed;
        if (!text || !rducks_parse_uuid_text(text, &parsed)) return 0;
        ((duckdb_hugeint *)data)[row] = parsed;
        rducks_output_set_valid(vector, row);
        return 1;
    }
    case RDUCKS_TYPE_INTERVAL: {
        SEXP months = rducks_list_elt_by_name_or_pos(value, "months", 0);
        SEXP days = rducks_list_elt_by_name_or_pos(value, "days", 1);
        SEXP micros = rducks_list_elt_by_name_or_pos(value, "micros", 2);
        const char *micros_text;
        duckdb_hugeint parsed;
        __int128 micro_value;
        double month_value;
        double day_value;
        if (months == R_NilValue || days == R_NilValue || micros == R_NilValue || XLENGTH(months) <= index ||
            XLENGTH(days) <= index || XLENGTH(micros) <= index) return 0;
        if (rducks_sexp_is_null_scalar(months, index) || rducks_sexp_is_null_scalar(days, index) ||
            rducks_sexp_is_null_scalar(micros, index)) {
            rducks_output_set_null(vector, row);
            return 1;
        }
        if (TYPEOF(months) == INTSXP) month_value = (double)INTEGER(months)[index];
        else if (TYPEOF(months) == REALSXP) month_value = REAL(months)[index];
        else return 0;
        if (TYPEOF(days) == INTSXP) day_value = (double)INTEGER(days)[index];
        else if (TYPEOF(days) == REALSXP) day_value = REAL(days)[index];
        else return 0;
        if (month_value != (double)((int32_t)month_value) || day_value != (double)((int32_t)day_value)) return 0;
        micros_text = rducks_string_at(micros, index);
        if (!micros_text || !rducks_parse_hugeint_text(micros_text, &parsed)) return 0;
        micro_value = rducks_hugeint_to_i128(parsed);
        if (month_value < -2147483648.0 || month_value > 2147483647.0 || day_value < -2147483648.0 ||
            day_value > 2147483647.0 || micro_value < -(((__int128)1) << 63) ||
            micro_value > (((__int128)1) << 63) - 1) return 0;
        ((duckdb_interval *)data)[row].months = (int32_t)month_value;
        ((duckdb_interval *)data)[row].days = (int32_t)day_value;
        ((duckdb_interval *)data)[row].micros = (int64_t)micro_value;
        rducks_output_set_valid(vector, row);
        return 1;
    }
    case RDUCKS_TYPE_BIT: {
        SEXP raw_data = rducks_list_elt_by_name_or_pos(value, "data", 0);
        SEXP len_value = rducks_list_elt_by_name_or_pos(value, "length", 1);
        int bit_len;
        idx_t internal_size;
        uint8_t *bytes;
        if (raw_data == R_NilValue || len_value == R_NilValue || TYPEOF(raw_data) != RAWSXP) return 0;
        bit_len = Rf_asInteger(len_value);
        if (bit_len <= 0 || (R_xlen_t)((bit_len + 7) / 8) > XLENGTH(raw_data)) return 0;
        internal_size = (idx_t)((bit_len + 7) / 8 + 1);
        bytes = (uint8_t *)calloc((size_t)internal_size, 1);
        if (!bytes) return 0;
        bytes[0] = (uint8_t)((8 - (bit_len % 8)) % 8);
        for (uint8_t p = 0; p < bytes[0]; p++) bytes[1] |= (uint8_t)(1U << (7 - p));
        for (int j = 0; j < bit_len; j++) {
            int src_bit = (RAW(raw_data)[j / 8] & (uint8_t)(1U << (7 - (j % 8)))) != 0;
            int dest_pos = j + bytes[0];
            if (src_bit) bytes[1 + dest_pos / 8] |= (uint8_t)(1U << (7 - (dest_pos % 8)));
        }
        duckdb_vector_assign_string_element_len(vector, row, (const char *)bytes, internal_size);
        free(bytes);
        rducks_output_set_valid(vector, row);
        return 1;
    }
    default:
        return 0;
    }
}

static int rducks_write_sequence_elements(const rducks_type_desc_t *child_desc, duckdb_vector child_vector,
                                          idx_t offset, SEXP value, idx_t len) {
    if (child_desc->kind == RDUCKS_KIND_SCALAR && rducks_scalar_can_atomic_vector(child_desc->scalar) &&
        (TYPEOF(value) != VECSXP || Rf_inherits(value, "rducks_interval"))) {
        if ((idx_t)rducks_sequence_length(value) < len) return 0;
        for (idx_t i = 0; i < len; i++) {
            if (!rducks_write_scalar_value_to_vector(child_desc->scalar, child_vector, offset + i, value, (R_xlen_t)i)) {
                return 0;
            }
        }
        return 1;
    }
    if (TYPEOF(value) != VECSXP || (idx_t)XLENGTH(value) < len) return 0;
    for (idx_t i = 0; i < len; i++) {
        if (!rducks_write_value_to_vector(child_desc, child_vector, offset + i, VECTOR_ELT(value, i))) return 0;
    }
    return 1;
}

static int rducks_write_list_value_to_vector(const rducks_type_desc_t *desc, duckdb_vector vector, idx_t row,
                                             SEXP value) {
    idx_t len = (idx_t)rducks_sequence_length(value);
    idx_t offset = duckdb_list_vector_get_size(vector);
    duckdb_list_entry *entries;
    duckdb_vector child;
    if (value == R_NilValue) {
        rducks_output_set_null(vector, row);
        return 1;
    }
    if (duckdb_list_vector_reserve(vector, offset + len) == DuckDBError ||
        duckdb_list_vector_set_size(vector, offset + len) == DuckDBError) {
        return 0;
    }
    entries = (duckdb_list_entry *)duckdb_vector_get_data(vector);
    entries[row].offset = offset;
    entries[row].length = len;
    child = duckdb_list_vector_get_child(vector);
    if (!rducks_write_sequence_elements(desc->child, child, offset, value, len)) return 0;
    rducks_output_set_valid(vector, row);
    return 1;
}

static int rducks_write_array_value_to_vector(const rducks_type_desc_t *desc, duckdb_vector vector, idx_t row,
                                              SEXP value) {
    idx_t len = desc->array_size;
    duckdb_vector child;
    if (value == R_NilValue) {
        rducks_output_set_null(vector, row);
        return 1;
    }
    if ((idx_t)rducks_sequence_length(value) != len) return 0;
    child = duckdb_array_vector_get_child(vector);
    if (!rducks_write_sequence_elements(desc->child, child, row * len, value, len)) return 0;
    rducks_output_set_valid(vector, row);
    return 1;
}

static int rducks_write_struct_value_to_vector(const rducks_type_desc_t *desc, duckdb_vector vector, idx_t row,
                                               SEXP value) {
    if (value == R_NilValue) {
        rducks_output_set_null(vector, row);
        return 1;
    }
    if (TYPEOF(value) != VECSXP) return 0;
    rducks_output_set_valid(vector, row);
    for (size_t i = 0; i < desc->field_count; i++) {
        duckdb_vector child = duckdb_struct_vector_get_child(vector, (idx_t)i);
        SEXP field = rducks_list_elt_by_name_or_pos(value, desc->field_names[i], (R_xlen_t)i);
        if (!rducks_write_value_to_vector(desc->field_types[i], child, row, field)) return 0;
    }
    return 1;
}

static int rducks_write_decimal_value_to_vector(const rducks_type_desc_t *desc, duckdb_vector vector, idx_t row,
                                                SEXP value) {
    SEXP value_field;
    const char *text;
    duckdb_hugeint parsed;
    if (value == R_NilValue) {
        rducks_output_set_null(vector, row);
        return 1;
    }
    value_field = TYPEOF(value) == VECSXP ? rducks_list_elt_by_name_or_pos(value, "value", 0) : value;
    if (value_field == R_NilValue || XLENGTH(value_field) == 0 || rducks_sexp_is_null_scalar(value_field, 0)) {
        rducks_output_set_null(vector, row);
        return 1;
    }
    text = rducks_string_at(value_field, 0);
    if (!text || !rducks_parse_decimal_text(text, desc->decimal_width, desc->decimal_scale, &parsed)) return 0;
    if (!rducks_decimal_storage_write(desc->decimal_width, duckdb_vector_get_data(vector), row, parsed)) return 0;
    rducks_output_set_valid(vector, row);
    return 1;
}

static int rducks_write_enum_value_to_vector(const rducks_type_desc_t *desc, duckdb_vector vector, idx_t row,
                                             SEXP value) {
    const char *text;
    size_t match = SIZE_MAX;
    void *data = duckdb_vector_get_data(vector);
    if (value == R_NilValue) {
        rducks_output_set_null(vector, row);
        return 1;
    }
    text = rducks_string_at(value, 0);
    if (!text) {
        rducks_output_set_null(vector, row);
        return 1;
    }
    for (size_t i = 0; i < desc->field_count; i++) {
        if (strcmp(text, desc->field_names[i]) == 0) {
            match = i;
            break;
        }
    }
    if (match == SIZE_MAX) return 0;
    if (desc->field_count <= 255U) ((uint8_t *)data)[row] = (uint8_t)match;
    else if (desc->field_count <= 65535U) ((uint16_t *)data)[row] = (uint16_t)match;
    else ((uint32_t *)data)[row] = (uint32_t)match;
    rducks_output_set_valid(vector, row);
    return 1;
}

static int rducks_write_union_value_to_vector(const rducks_type_desc_t *desc, duckdb_vector vector, idx_t row,
                                              SEXP value) {
    SEXP tag_value;
    SEXP member_value;
    const char *tag_text;
    size_t tag = SIZE_MAX;
    duckdb_vector tag_vector;
    uint8_t *tags;
    if (value == R_NilValue) {
        duckdb_vector tag_vec = duckdb_struct_vector_get_child(vector, 0);
        rducks_output_set_null(vector, row);
        rducks_output_set_null(tag_vec, row);
        return 1;
    }
    if (TYPEOF(value) != VECSXP) return 0;
    tag_value = rducks_list_elt_by_name_or_pos(value, "tag", 0);
    member_value = rducks_list_elt_by_name_or_pos(value, "value", 1);
    tag_text = rducks_string_at(tag_value, 0);
    if (!tag_text) return 0;
    for (size_t i = 0; i < desc->field_count; i++) {
        if (strcmp(tag_text, desc->field_names[i]) == 0) {
            tag = i;
            break;
        }
    }
    if (tag == SIZE_MAX || tag > 255U) return 0;
    rducks_output_set_valid(vector, row);
    tag_vector = duckdb_struct_vector_get_child(vector, 0);
    tags = (uint8_t *)duckdb_vector_get_data(tag_vector);
    tags[row] = (uint8_t)tag;
    rducks_output_set_valid(tag_vector, row);
    for (size_t i = 0; i < desc->field_count; i++) {
        duckdb_vector child = duckdb_struct_vector_get_child(vector, (idx_t)i + 1);
        if (i == tag) {
            if (!rducks_write_value_to_vector(desc->field_types[i], child, row, member_value)) return 0;
        } else {
            rducks_output_set_null(child, row);
        }
    }
    return 1;
}

static int rducks_write_map_value_to_vector(const rducks_type_desc_t *desc, duckdb_vector vector, idx_t row,
                                            SEXP value) {
    SEXP keys;
    SEXP values;
    idx_t len;
    idx_t offset;
    duckdb_list_entry *entries;
    duckdb_vector child;
    duckdb_vector key_vector;
    duckdb_vector value_vector;
    if (value == R_NilValue) {
        rducks_output_set_null(vector, row);
        return 1;
    }
    if (TYPEOF(value) != VECSXP) return 0;
    keys = rducks_list_elt_by_name_or_pos(value, "keys", 0);
    values = rducks_list_elt_by_name_or_pos(value, "values", 1);
    len = (idx_t)rducks_sequence_length(keys);
    if ((idx_t)rducks_sequence_length(values) != len) return 0;
    offset = duckdb_list_vector_get_size(vector);
    if (duckdb_list_vector_reserve(vector, offset + len) == DuckDBError ||
        duckdb_list_vector_set_size(vector, offset + len) == DuckDBError) {
        return 0;
    }
    entries = (duckdb_list_entry *)duckdb_vector_get_data(vector);
    entries[row].offset = offset;
    entries[row].length = len;
    child = duckdb_list_vector_get_child(vector);
    key_vector = duckdb_struct_vector_get_child(child, 0);
    value_vector = duckdb_struct_vector_get_child(child, 1);
    if (!rducks_write_sequence_elements(desc->key, key_vector, offset, keys, len)) return 0;
    if (!rducks_write_sequence_elements(desc->value, value_vector, offset, values, len)) return 0;
    rducks_output_set_valid(vector, row);
    return 1;
}

static int rducks_write_value_to_vector(const rducks_type_desc_t *desc, duckdb_vector vector, idx_t row, SEXP value) {
    if (!desc) return 0;
    if (value == R_NilValue) {
        rducks_output_set_null(vector, row);
        return 1;
    }
    switch (desc->kind) {
    case RDUCKS_KIND_SCALAR:
        return rducks_write_scalar_value_to_vector(desc->scalar, vector, row, value, 0);
    case RDUCKS_KIND_LIST:
        return rducks_write_list_value_to_vector(desc, vector, row, value);
    case RDUCKS_KIND_ARRAY:
        return rducks_write_array_value_to_vector(desc, vector, row, value);
    case RDUCKS_KIND_STRUCT:
        return rducks_write_struct_value_to_vector(desc, vector, row, value);
    case RDUCKS_KIND_MAP:
        return rducks_write_map_value_to_vector(desc, vector, row, value);
    case RDUCKS_KIND_DECIMAL:
        return rducks_write_decimal_value_to_vector(desc, vector, row, value);
    case RDUCKS_KIND_ENUM:
        return rducks_write_enum_value_to_vector(desc, vector, row, value);
    case RDUCKS_KIND_UNION:
        return rducks_write_union_value_to_vector(desc, vector, row, value);
    default:
        return 0;
    }
}

static int rducks_write_compiled_result(rducks_r_scalar_meta_t *meta, duckdb_vector output, idx_t row, void *out_value,
                                         bool out_is_null) {
    if (out_is_null) {
        rducks_output_set_null(output, row);
        return 1;
    }
    if (meta->return_desc && rducks_desc_uses_sexp_bridge(meta->return_desc)) {
        SEXP value = *(SEXP *)out_value;
        int ok;
        if (value == R_NilValue) {
            rducks_output_set_null(output, row);
            return 1;
        }
        ok = rducks_write_value_to_vector(meta->return_desc, output, row, value);
        R_ReleaseObject(value);
        return ok;
    }
    if (meta->returns == RDUCKS_TYPE_VARCHAR) {
        char *value = *(char **)out_value;
        if (!value) {
            rducks_output_set_null(output, row);
            return 1;
        }
        duckdb_vector_assign_string_element(output, row, value);
        free(value);
        rducks_output_set_valid(output, row);
        return 1;
    }
    if (meta->returns == RDUCKS_TYPE_BLOB) {
        rducks_blob_t *value = (rducks_blob_t *)out_value;
        if (!value->ptr && value->len > 0U) {
            rducks_output_set_null(output, row);
            return 1;
        }
        duckdb_vector_assign_string_element_len(output, row, value->ptr ? (const char *)value->ptr : "", (idx_t)value->len);
        free((void *)value->ptr);
        rducks_output_set_valid(output, row);
        return 1;
    }
    if (meta->return_size > 0U) {
        uint8_t *out_data = (uint8_t *)duckdb_vector_get_data(output);
        memcpy(out_data + ((size_t)row * meta->return_size), out_value, meta->return_size);
    }
    rducks_output_set_valid(output, row);
    return 1;
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
        int arg_protect_count = 0;
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
                                        &arg_allocs[col], &arg_protect_count)) {
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
            if (arg_protect_count) UNPROTECT(arg_protect_count);
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
                if (arg_protect_count) UNPROTECT(arg_protect_count);
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
                if (arg_protect_count) UNPROTECT(arg_protect_count);
                continue;
            }
            if (arg_allocs) {
                for (size_t col = 0; col < meta->arity; col++) {
                    free(arg_allocs[col]);
                }
            }
            if (arg_protect_count) UNPROTECT(arg_protect_count);
            free(arg_ptrs);
            free(arg_is_null);
            free(arg_allocs);
            duckdb_scalar_function_set_error(info, "Rducks compiled callback raised an error");
            return;
        }
        if (!rducks_write_compiled_result(meta, output, row, (void *)out_value, out_is_null)) {
            if (arg_allocs) {
                for (size_t col = 0; col < meta->arity; col++) {
                    free(arg_allocs[col]);
                }
            }
            if (arg_protect_count) UNPROTECT(arg_protect_count);
            free(arg_ptrs);
            free(arg_is_null);
            free(arg_allocs);
            duckdb_scalar_function_set_error(info, "Rducks failed to marshal callback result");
            return;
        }
        if (arg_allocs) {
            for (size_t col = 0; col < meta->arity; col++) {
                free(arg_allocs[col]);
            }
        }
        if (arg_protect_count) UNPROTECT(arg_protect_count);
    }

    free(arg_ptrs);
    free(arg_is_null);
    free(arg_allocs);
}

static bool rducks_register_r_scalar(const char *name, SEXP fun, SEXP compiled, void *wrapper_ptr, const char *args_spec,
                                     const char *return_spec, const char *null_handling_spec,
                                     const char *exception_handling_spec, bool side_effects, char *err,
                                     size_t err_cap) {
    rducks_type_desc_t **arg_descs = NULL;
    rducks_type_desc_t *return_desc = NULL;
    size_t arity = 0;
    rducks_type_id_t return_type;
    rducks_null_handling_t null_handling;
    rducks_exception_handling_t exception_handling;
    rducks_r_scalar_meta_t *meta = NULL;
    duckdb_scalar_function fn = NULL;
    duckdb_logical_type return_logical_type = NULL;
    duckdb_state rc;
    if (!g_connection || !name || !name[0] || !Rf_isFunction(fun) || !compiled || compiled == R_NilValue ||
        !wrapper_ptr) {
        snprintf(err, err_cap, "invalid Rducks scalar registration request");
        return false;
    }
    if (!rducks_parse_type_list(args_spec, &arg_descs, &arity, err, err_cap)) {
        return false;
    }
    if (!rducks_parse_type_desc_text(return_spec, &return_desc, err, err_cap)) {
        for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
        free(arg_descs);
        return false;
    }
    return_type = return_desc->kind == RDUCKS_KIND_SCALAR ? return_desc->scalar : RDUCKS_TYPE_INVALID;
    if (!rducks_parse_null_handling(null_handling_spec, &null_handling, err, err_cap)) {
        for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
        free(arg_descs);
        rducks_type_desc_destroy(return_desc);
        return false;
    }
    if (!rducks_parse_exception_handling(exception_handling_spec, &exception_handling, err, err_cap)) {
        for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
        free(arg_descs);
        rducks_type_desc_destroy(return_desc);
        return false;
    }

    fn = duckdb_create_scalar_function();
    return_logical_type = rducks_create_logical_type_for_desc(return_desc);
    if (!fn || !return_logical_type) {
        snprintf(err, err_cap, "failed to allocate DuckDB scalar function for Rducks UDF");
        if (fn) {
            duckdb_destroy_scalar_function(&fn);
        }
        if (return_logical_type) {
            duckdb_destroy_logical_type(&return_logical_type);
        }
        for (size_t j = 0; j < arity; j++) rducks_type_desc_destroy(arg_descs[j]);
        free(arg_descs);
        rducks_type_desc_destroy(return_desc);
        return false;
    }

    duckdb_scalar_function_set_name(fn, name);
    for (size_t i = 0; i < arity; i++) {
        duckdb_logical_type arg_logical_type = rducks_create_logical_type_for_desc(arg_descs[i]);
        if (!arg_logical_type) {
            snprintf(err, err_cap, "failed to allocate DuckDB logical type for Rducks argument %zu", i + 1);
            duckdb_destroy_scalar_function(&fn);
            duckdb_destroy_logical_type(&return_logical_type);
            for (size_t j = 0; j < arity; j++) rducks_type_desc_destroy(arg_descs[j]);
        free(arg_descs);
        rducks_type_desc_destroy(return_desc);
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
        for (size_t j = 0; j < arity; j++) rducks_type_desc_destroy(arg_descs[j]);
        free(arg_descs);
        rducks_type_desc_destroy(return_desc);
        return false;
    }
    meta->fun = R_NilValue;
    meta->compiled = R_NilValue;
    meta->wrapper = (rducks_scalar_wrapper_fn_t)wrapper_ptr;
    meta->arity = arity;
    meta->args = arg_descs;
    arg_descs = NULL;
    meta->return_desc = return_desc;
    return_desc = NULL;
    meta->returns = return_type;
    meta->return_size = rducks_desc_uses_sexp_bridge(meta->return_desc) ? sizeof(SEXP) : rducks_type_size(return_type);
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
        meta->arg_sizes[i] = (meta->args[i] && meta->args[i]->kind == RDUCKS_KIND_SCALAR &&
                              !rducks_scalar_uses_sexp_bridge(meta->args[i]->scalar)) ?
                                 rducks_type_size(meta->args[i]->scalar) : 0U;
    }
    meta->fun = fun;
    meta->compiled = compiled;
    R_PreserveObject(fun);
    R_PreserveObject(compiled);

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
    uint64_t *compiled_ptrs = (uint64_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 3));
    duckdb_string_t *args_specs = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 4));
    duckdb_string_t *return_specs = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 5));
    duckdb_string_t *null_handling_specs =
        (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 6));
    duckdb_string_t *exception_handling_specs =
        (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 7));
    bool *side_effects_values = (bool *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 8));
    bool *out = (bool *)duckdb_vector_get_data(output);

    for (idx_t i = 0; i < n; i++) {
        char *name = rducks_copy_duckdb_string(&names[i]);
        char *args_spec = rducks_copy_duckdb_string(&args_specs[i]);
        char *return_spec = rducks_copy_duckdb_string(&return_specs[i]);
        char *null_handling_spec = rducks_copy_duckdb_string(&null_handling_specs[i]);
        char *exception_handling_spec = rducks_copy_duckdb_string(&exception_handling_specs[i]);
        char err[256];
        SEXP fun;
        SEXP compiled;
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
        compiled = (SEXP)(uintptr_t)compiled_ptrs[i];
        wrapper_ptr = (void *)(uintptr_t)wrapper_ptrs[i];
        out[i] = rducks_register_r_scalar(name, fun, compiled, wrapper_ptr, args_spec, return_spec, null_handling_spec,
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

static bool rducks_unregister_r_scalar(const char *name, const char *args_spec, const char *return_spec, char *err,
                                       size_t err_cap) {
    rducks_type_desc_t **arg_descs = NULL;
    rducks_type_desc_t *return_desc = NULL;
    size_t arity = 0;
    duckdb_scalar_function fn = NULL;
    duckdb_logical_type return_logical_type = NULL;
    rducks_inactive_scalar_meta_t *meta = NULL;
    duckdb_state rc;
    if (!g_connection || !name || !name[0]) {
        snprintf(err, err_cap, "invalid Rducks scalar unregister request");
        return false;
    }
    if (!rducks_parse_type_list(args_spec, &arg_descs, &arity, err, err_cap)) {
        return false;
    }
    if (!rducks_parse_type_desc_text(return_spec, &return_desc, err, err_cap)) {
        for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
        free(arg_descs);
        return false;
    }
    fn = duckdb_create_scalar_function();
    return_logical_type = rducks_create_logical_type_for_desc(return_desc);
    if (!fn || !return_logical_type) {
        snprintf(err, err_cap, "failed to allocate DuckDB scalar function for Rducks unregister");
        if (fn) duckdb_destroy_scalar_function(&fn);
        if (return_logical_type) duckdb_destroy_logical_type(&return_logical_type);
        for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
        free(arg_descs);
        rducks_type_desc_destroy(return_desc);
        return false;
    }

    duckdb_scalar_function_set_name(fn, name);
    for (size_t i = 0; i < arity; i++) {
        duckdb_logical_type arg_logical_type = rducks_create_logical_type_for_desc(arg_descs[i]);
        if (!arg_logical_type) {
            snprintf(err, err_cap, "failed to allocate DuckDB logical type for Rducks argument %zu", i + 1);
            duckdb_destroy_scalar_function(&fn);
            duckdb_destroy_logical_type(&return_logical_type);
            for (size_t j = 0; j < arity; j++) rducks_type_desc_destroy(arg_descs[j]);
            free(arg_descs);
            rducks_type_desc_destroy(return_desc);
            return false;
        }
        duckdb_scalar_function_add_parameter(fn, arg_logical_type);
        duckdb_destroy_logical_type(&arg_logical_type);
    }

    meta = (rducks_inactive_scalar_meta_t *)calloc(1, sizeof(rducks_inactive_scalar_meta_t));
    if (!meta) {
        snprintf(err, err_cap, "out of memory");
        duckdb_destroy_scalar_function(&fn);
        duckdb_destroy_logical_type(&return_logical_type);
        for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
        free(arg_descs);
        rducks_type_desc_destroy(return_desc);
        return false;
    }
    meta->name = rducks_strdup_len(name, strlen(name));
    if (!meta->name) {
        snprintf(err, err_cap, "out of memory");
        rducks_inactive_scalar_meta_destroy(meta);
        duckdb_destroy_scalar_function(&fn);
        duckdb_destroy_logical_type(&return_logical_type);
        for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
        free(arg_descs);
        rducks_type_desc_destroy(return_desc);
        return false;
    }

    duckdb_scalar_function_set_return_type(fn, return_logical_type);
    duckdb_scalar_function_set_special_handling(fn);
    duckdb_scalar_function_set_extra_info(fn, meta, rducks_inactive_scalar_meta_destroy);
    meta = NULL;
    duckdb_scalar_function_set_function(fn, rducks_inactive_scalar_udf);
    rc = duckdb_register_scalar_function(g_connection, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&return_logical_type);
    for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
    free(arg_descs);
    rducks_type_desc_destroy(return_desc);
    if (rc != DuckDBSuccess) {
        snprintf(err, err_cap, "DuckDB failed to unregister Rducks scalar UDF %s", name);
        return false;
    }
    return true;
}

static void rducks_unregister_scalar_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    idx_t n = duckdb_data_chunk_get_size(input);
    duckdb_string_t *names = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 0));
    duckdb_string_t *args_specs = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 1));
    duckdb_string_t *return_specs = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 2));
    bool *out = (bool *)duckdb_vector_get_data(output);

    for (idx_t i = 0; i < n; i++) {
        char *name = rducks_copy_duckdb_string(&names[i]);
        char *args_spec = rducks_copy_duckdb_string(&args_specs[i]);
        char *return_spec = rducks_copy_duckdb_string(&return_specs[i]);
        char err[256];
        err[0] = '\0';
        if (!name || !args_spec || !return_spec) {
            free(name);
            free(args_spec);
            free(return_spec);
            duckdb_scalar_function_set_error(info, "out of memory");
            return;
        }
        out[i] = rducks_unregister_r_scalar(name, args_spec, return_spec, err, sizeof(err));
        free(name);
        free(args_spec);
        free(return_spec);
        if (!out[i]) {
            duckdb_scalar_function_set_error(info, err[0] ? err : "Rducks scalar unregister failed");
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

static bool rducks_register_unregister_surface(duckdb_connection con) {
    duckdb_scalar_function fn = duckdb_create_scalar_function();
    duckdb_logical_type varchar_type = duckdb_create_logical_type(DUCKDB_TYPE_VARCHAR);
    duckdb_logical_type bool_type = duckdb_create_logical_type(DUCKDB_TYPE_BOOLEAN);
    duckdb_state rc;
    if (!fn || !varchar_type || !bool_type) {
        if (fn) duckdb_destroy_scalar_function(&fn);
        if (varchar_type) duckdb_destroy_logical_type(&varchar_type);
        if (bool_type) duckdb_destroy_logical_type(&bool_type);
        return false;
    }
    duckdb_scalar_function_set_name(fn, "rducks_unregister_scalar");
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_set_return_type(fn, bool_type);
    duckdb_scalar_function_set_volatile(fn);
    duckdb_scalar_function_set_function(fn, rducks_unregister_scalar_scalar);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&varchar_type);
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
        if (!rducks_register_version(g_connection) || !rducks_register_scalar_surface(g_connection) ||
            !rducks_register_unregister_surface(g_connection)) {
            if (access) {
                access->set_error(info, "failed to register Rducks SQL surface");
            }
            return false;
        }
        g_registration_surface_ready = 1;
    }
    return true;
}
