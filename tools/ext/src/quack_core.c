/* Rducks Quack wire core implementation. See quack_core.h for the grammar.
 * Pure C99: no R API, no DuckDB headers; safe on any thread. */

#include "quack_core.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static void rdx_qk_set_error(rdx_qk_error *err, const char *msg) {
    if (!err) return;
    snprintf(err->message, sizeof(err->message), "%s", msg ? msg : "unknown quack wire error");
}

size_t rdx_qk_validity_bytes(uint64_t rows) {
    return (size_t)(((rows + 63u) / 64u) * 8u);
}

/* ---------------- type tree ---------------- */

rdx_qk_type *rdx_qk_type_new(uint32_t id) {
    rdx_qk_type *t = (rdx_qk_type *)calloc(1, sizeof(rdx_qk_type));
    if (t) t->id = id;
    return t;
}

void rdx_qk_type_free(rdx_qk_type *t) {
    uint32_t i;
    if (!t) return;
    for (i = 0; i < t->nchildren; i++) {
        rdx_qk_type_free(t->children ? t->children[i] : NULL);
        if (t->names && t->names[i]) free(t->names[i]);
    }
    free(t->children);
    free(t->names);
    for (i = 0; i < t->enum_count; i++) {
        if (t->enum_labels && t->enum_labels[i]) free(t->enum_labels[i]);
    }
    free(t->enum_labels);
    free(t);
}

static char *rdx_qk_strdup_n(const char *s, size_t n) {
    char *out = (char *)malloc(n + 1);
    if (!out) return NULL;
    if (n) memcpy(out, s, n);
    out[n] = '\0';
    return out;
}

int rdx_qk_type_add_child(rdx_qk_type *t, rdx_qk_type *child, const char *name) {
    rdx_qk_type **children;
    char **names;
    if (!t || !child) return 0;
    children = (rdx_qk_type **)realloc(t->children, (t->nchildren + 1) * sizeof(*children));
    if (!children) return 0;
    t->children = children;
    names = (char **)realloc(t->names, (t->nchildren + 1) * sizeof(*names));
    if (!names) return 0;
    t->names = names;
    t->names[t->nchildren] = name ? rdx_qk_strdup_n(name, strlen(name)) : rdx_qk_strdup_n("", 0);
    if (!t->names[t->nchildren]) return 0;
    t->children[t->nchildren] = child;
    t->nchildren++;
    return 1;
}

int rdx_qk_type_set_enum_labels(rdx_qk_type *t, const char *const *labels, uint32_t n) {
    uint32_t i;
    if (!t) return 0;
    t->enum_labels = (char **)calloc(n ? n : 1, sizeof(char *));
    if (!t->enum_labels) return 0;
    for (i = 0; i < n; i++) {
        t->enum_labels[i] = rdx_qk_strdup_n(labels[i], strlen(labels[i]));
        if (!t->enum_labels[i]) return 0;
        t->enum_count = i + 1;
    }
    t->enum_count = n;
    return 1;
}

static size_t rdx_qk_enum_physical_width(uint32_t enum_count) {
    if (enum_count <= 0xffu) return 1;
    if (enum_count <= 0xffffu) return 2;
    return 4;
}

size_t rdx_qk_type_fixed_width(const rdx_qk_type *t) {
    switch (t->id) {
    case RDX_QK_LTYPE_BOOLEAN: return 1;
    case RDX_QK_LTYPE_TINYINT: case RDX_QK_LTYPE_UTINYINT: return 1;
    case RDX_QK_LTYPE_SMALLINT: case RDX_QK_LTYPE_USMALLINT: return 2;
    case RDX_QK_LTYPE_INTEGER: case RDX_QK_LTYPE_UINTEGER:
    case RDX_QK_LTYPE_DATE: case RDX_QK_LTYPE_FLOAT:
        return 4;
    case RDX_QK_LTYPE_BIGINT: case RDX_QK_LTYPE_UBIGINT:
    case RDX_QK_LTYPE_DOUBLE: case RDX_QK_LTYPE_TIME:
    case RDX_QK_LTYPE_TIME_TZ:
    case RDX_QK_LTYPE_TIMESTAMP: case RDX_QK_LTYPE_TIMESTAMP_SEC:
    case RDX_QK_LTYPE_TIMESTAMP_MS: case RDX_QK_LTYPE_TIMESTAMP_NS:
    case RDX_QK_LTYPE_TIMESTAMP_TZ:
        return 8;
    case RDX_QK_LTYPE_HUGEINT: case RDX_QK_LTYPE_UHUGEINT:
    case RDX_QK_LTYPE_UUID: case RDX_QK_LTYPE_INTERVAL:
        return 16;
    case RDX_QK_LTYPE_DECIMAL:
        if (t->width <= 4) return 2;
        if (t->width <= 9) return 4;
        if (t->width <= 18) return 8;
        return 16;
    case RDX_QK_LTYPE_ENUM:
        return rdx_qk_enum_physical_width(t->enum_count);
    default:
        return 0;
    }
}

int rdx_qk_type_equal(const rdx_qk_type *a, const rdx_qk_type *b) {
    uint32_t i;
    if (a == b) return 1;
    if (!a || !b) return 0;
    if (a->id != b->id || a->width != b->width || a->scale != b->scale ||
        a->array_size != b->array_size || a->nchildren != b->nchildren ||
        a->enum_count != b->enum_count) {
        return 0;
    }
    for (i = 0; i < a->nchildren; i++) {
        const char *an = (a->names && a->names[i]) ? a->names[i] : "";
        const char *bn = (b->names && b->names[i]) ? b->names[i] : "";
        if (strcmp(an, bn) != 0) return 0;
        if (!rdx_qk_type_equal(a->children[i], b->children[i])) return 0;
    }
    for (i = 0; i < a->enum_count; i++) {
        if (strcmp(a->enum_labels[i], b->enum_labels[i]) != 0) return 0;
    }
    return 1;
}

/* ---------------- vector model ---------------- */

rdx_qk_vector *rdx_qk_vector_new(const rdx_qk_type *type, uint64_t rows) {
    rdx_qk_vector *v = (rdx_qk_vector *)calloc(1, sizeof(rdx_qk_vector));
    if (!v) return NULL;
    v->type = type;
    v->rows = rows;
    return v;
}

void rdx_qk_vector_free(rdx_qk_vector *v) {
    uint32_t i;
    if (!v) return;
    free(v->validity);
    free(v->data);
    free(v->str_offsets);
    free(v->str_pool);
    free(v->list_offsets);
    free(v->list_lengths);
    for (i = 0; i < v->nchildren; i++) rdx_qk_vector_free(v->children ? v->children[i] : NULL);
    free(v->children);
    free(v);
}

int rdx_qk_vector_alloc_validity(rdx_qk_vector *v) {
    size_t n = rdx_qk_validity_bytes(v->rows);
    if (v->validity) return 1;
    v->validity = (uint8_t *)malloc(n ? n : 1);
    if (!v->validity) return 0;
    memset(v->validity, 0xff, n); /* all valid */
    v->has_validity = 1;
    return 1;
}

void rdx_qk_vector_set_null(rdx_qk_vector *v, uint64_t row) {
    if (!v->validity && !rdx_qk_vector_alloc_validity(v)) return;
    v->validity[row >> 3] &= (uint8_t)~(1u << (row & 7u));
}

int rdx_qk_vector_row_is_valid(const rdx_qk_vector *v, uint64_t row) {
    if (!v->has_validity || !v->validity) return 1;
    return (v->validity[row >> 3] >> (row & 7u)) & 1u;
}

int rdx_qk_vector_alloc_fixed(rdx_qk_vector *v) {
    size_t width = rdx_qk_type_fixed_width(v->type);
    size_t n;
    if (width == 0) return 0;
    if (v->rows > SIZE_MAX / width) return 0;
    n = width * (size_t)v->rows;
    v->data = (uint8_t *)calloc(n ? n : 1, 1);
    if (!v->data) return 0;
    v->data_size = n;
    return 1;
}

int rdx_qk_vector_alloc_strings(rdx_qk_vector *v, size_t pool_bytes) {
    v->str_offsets = (uint64_t *)calloc((size_t)v->rows + 1, sizeof(uint64_t));
    if (!v->str_offsets) return 0;
    v->str_pool = (uint8_t *)malloc(pool_bytes ? pool_bytes : 1);
    if (!v->str_pool) return 0;
    v->str_pool_size = pool_bytes;
    return 1;
}

int rdx_qk_vector_alloc_list(rdx_qk_vector *v, uint64_t child_rows) {
    v->list_offsets = (uint64_t *)calloc((size_t)v->rows ? (size_t)v->rows : 1, sizeof(uint64_t));
    v->list_lengths = (uint64_t *)calloc((size_t)v->rows ? (size_t)v->rows : 1, sizeof(uint64_t));
    if (!v->list_offsets || !v->list_lengths) return 0;
    v->list_child_rows = child_rows;
    return 1;
}

rdx_qk_chunk *rdx_qk_chunk_new(uint64_t rows, uint32_t ncolumns) {
    rdx_qk_chunk *c = (rdx_qk_chunk *)calloc(1, sizeof(rdx_qk_chunk));
    if (!c) return NULL;
    c->rows = rows;
    c->ncolumns = ncolumns;
    c->types = (rdx_qk_type **)calloc(ncolumns ? ncolumns : 1, sizeof(*c->types));
    c->columns = (rdx_qk_vector **)calloc(ncolumns ? ncolumns : 1, sizeof(*c->columns));
    if (!c->types || !c->columns) {
        rdx_qk_chunk_free(c);
        return NULL;
    }
    return c;
}

void rdx_qk_chunk_free(rdx_qk_chunk *c) {
    uint32_t i;
    if (!c) return;
    for (i = 0; i < c->ncolumns; i++) {
        if (c->columns) rdx_qk_vector_free(c->columns[i]);
        if (c->types) rdx_qk_type_free(c->types[i]);
    }
    free(c->columns);
    free(c->types);
    free(c);
}

/* ---------------- writer ---------------- */

void rdx_qk_writer_init(rdx_qk_writer *w) {
    memset(w, 0, sizeof(*w));
}

void rdx_qk_writer_destroy(rdx_qk_writer *w) {
    free(w->data);
    memset(w, 0, sizeof(*w));
}

uint8_t *rdx_qk_writer_detach(rdx_qk_writer *w, size_t *size_out) {
    uint8_t *out;
    if (w->oom) return NULL;
    out = w->data;
    if (size_out) *size_out = w->size;
    w->data = NULL;
    w->size = w->cap = 0;
    return out;
}

static int rdx_qk_writer_reserve(rdx_qk_writer *w, size_t add) {
    size_t need, cap;
    uint8_t *data;
    if (w->oom) return 0;
    if (w->size > SIZE_MAX - add) {
        w->oom = 1;
        return 0;
    }
    need = w->size + add;
    if (need <= w->cap) return 1;
    cap = w->cap ? w->cap : 256;
    while (cap < need) {
        if (cap > SIZE_MAX / 2) {
            cap = need;
            break;
        }
        cap *= 2;
    }
    data = (uint8_t *)realloc(w->data, cap);
    if (!data) {
        w->oom = 1;
        return 0;
    }
    w->data = data;
    w->cap = cap;
    return 1;
}

void rdx_qk_write_u8(rdx_qk_writer *w, uint8_t x) {
    if (!rdx_qk_writer_reserve(w, 1)) return;
    w->data[w->size++] = x;
}

void rdx_qk_write_bytes(rdx_qk_writer *w, const void *data, size_t n) {
    if (!rdx_qk_writer_reserve(w, n)) return;
    if (n) memcpy(w->data + w->size, data, n);
    w->size += n;
}

void rdx_qk_write_field(rdx_qk_writer *w, uint16_t field_id) {
    rdx_qk_write_u8(w, (uint8_t)(field_id & 0xffu));
    rdx_qk_write_u8(w, (uint8_t)((field_id >> 8) & 0xffu));
}

void rdx_qk_write_object_end(rdx_qk_writer *w) {
    rdx_qk_write_field(w, RDX_QK_OBJECT_END);
}

void rdx_qk_write_uleb(rdx_qk_writer *w, uint64_t x) {
    do {
        uint8_t byte = (uint8_t)(x & 0x7fu);
        x >>= 7;
        if (x) byte |= 0x80u;
        rdx_qk_write_u8(w, byte);
    } while (x);
}

void rdx_qk_write_sleb(rdx_qk_writer *w, int64_t x) {
    int more = 1;
    while (more) {
        uint8_t byte = (uint8_t)(x & 0x7f);
        int sign = byte & 0x40;
        x >>= 7;
        if ((x == 0 && !sign) || (x == -1 && sign)) {
            more = 0;
        } else {
            byte |= 0x80u;
        }
        rdx_qk_write_u8(w, byte);
    }
}

void rdx_qk_write_string(rdx_qk_writer *w, const char *s, size_t n) {
    rdx_qk_write_uleb(w, (uint64_t)n);
    rdx_qk_write_bytes(w, s, n);
}

void rdx_qk_write_data(rdx_qk_writer *w, const void *data, size_t n) {
    rdx_qk_write_uleb(w, (uint64_t)n);
    rdx_qk_write_bytes(w, data, n);
}

/* ---------------- reader ---------------- */

void rdx_qk_reader_init(rdx_qk_reader *r, const uint8_t *data, size_t size) {
    r->data = data;
    r->size = size;
    r->pos = 0;
}

int rdx_qk_read_u8(rdx_qk_reader *r, uint8_t *out, rdx_qk_error *err) {
    if (r->pos >= r->size) {
        rdx_qk_set_error(err, "quack wire payload is truncated");
        return 0;
    }
    *out = r->data[r->pos++];
    return 1;
}

int rdx_qk_read_field(rdx_qk_reader *r, uint16_t *out, rdx_qk_error *err) {
    uint8_t lo, hi;
    if (!rdx_qk_read_u8(r, &lo, err) || !rdx_qk_read_u8(r, &hi, err)) return 0;
    *out = (uint16_t)(lo | ((uint16_t)hi << 8));
    return 1;
}

int rdx_qk_read_uleb(rdx_qk_reader *r, uint64_t *out, rdx_qk_error *err) {
    uint64_t value = 0;
    unsigned shift = 0;
    uint8_t byte;
    for (;;) {
        if (!rdx_qk_read_u8(r, &byte, err)) return 0;
        if (shift == 63 && (byte & 0x7eu)) {
            rdx_qk_set_error(err, "quack wire ULEB128 value overflows 64 bits");
            return 0;
        }
        if (shift > 63) {
            rdx_qk_set_error(err, "quack wire ULEB128 value overflows 64 bits");
            return 0;
        }
        value |= ((uint64_t)(byte & 0x7fu)) << shift;
        if (!(byte & 0x80u)) break;
        shift += 7;
    }
    *out = value;
    return 1;
}

int rdx_qk_read_sleb(rdx_qk_reader *r, int64_t *out, rdx_qk_error *err) {
    uint64_t value = 0;
    unsigned shift = 0;
    uint8_t byte;
    for (;;) {
        if (!rdx_qk_read_u8(r, &byte, err)) return 0;
        if (shift > 63) {
            rdx_qk_set_error(err, "quack wire SLEB128 value overflows 64 bits");
            return 0;
        }
        value |= ((uint64_t)(byte & 0x7fu)) << shift;
        shift += 7;
        if (!(byte & 0x80u)) {
            if (shift < 64 && (byte & 0x40u)) {
                value |= ~(uint64_t)0 << shift; /* sign-extend */
            }
            break;
        }
    }
    memcpy(out, &value, sizeof(value)); /* two's complement reinterpret */
    return 1;
}

static int rdx_qk_read_len_prefixed(rdx_qk_reader *r, const uint8_t **ptr, uint64_t *len,
                                    const char *what, rdx_qk_error *err) {
    uint64_t n;
    if (!rdx_qk_read_uleb(r, &n, err)) return 0;
    if (n > r->size - r->pos) {
        char msg[128];
        snprintf(msg, sizeof(msg), "quack wire %s exceeds payload size", what);
        rdx_qk_set_error(err, msg);
        return 0;
    }
    *ptr = r->data + r->pos;
    *len = n;
    r->pos += (size_t)n;
    return 1;
}

int rdx_qk_read_string(rdx_qk_reader *r, const uint8_t **ptr, uint64_t *len, rdx_qk_error *err) {
    return rdx_qk_read_len_prefixed(r, ptr, len, "string", err);
}

int rdx_qk_read_data(rdx_qk_reader *r, const uint8_t **ptr, uint64_t *len, rdx_qk_error *err) {
    return rdx_qk_read_len_prefixed(r, ptr, len, "raw data", err);
}

int rdx_qk_skip_bytes(rdx_qk_reader *r, uint64_t n, rdx_qk_error *err) {
    if (n > r->size - r->pos) {
        rdx_qk_set_error(err, "quack wire payload is truncated");
        return 0;
    }
    r->pos += (size_t)n;
    return 1;
}

/* ---------------- LogicalType codec ---------------- */

static int rdx_qk_type_needs_info(const rdx_qk_type *t) {
    switch (t->id) {
    case RDX_QK_LTYPE_DECIMAL:
    case RDX_QK_LTYPE_LIST:
    case RDX_QK_LTYPE_MAP:
    case RDX_QK_LTYPE_STRUCT:
    case RDX_QK_LTYPE_UNION:
    case RDX_QK_LTYPE_ENUM:
    case RDX_QK_LTYPE_ARRAY:
        return 1;
    default:
        return 0;
    }
}

static int rdx_qk_type_encode_depth(rdx_qk_writer *w, const rdx_qk_type *t,
                                    unsigned depth, rdx_qk_error *err);

static int rdx_qk_child_pair_encode(rdx_qk_writer *w, const char *name, const rdx_qk_type *t,
                                    unsigned depth, rdx_qk_error *err) {
    /* std::pair<string, LogicalType>: object{field 0 first, field 1 second}. */
    rdx_qk_write_field(w, 0);
    rdx_qk_write_string(w, name ? name : "", name ? strlen(name) : 0);
    rdx_qk_write_field(w, 1);
    if (!rdx_qk_type_encode_depth(w, t, depth, err)) return 0;
    rdx_qk_write_object_end(w);
    return 1;
}

static int rdx_qk_type_encode_depth(rdx_qk_writer *w, const rdx_qk_type *t,
                                    unsigned depth, rdx_qk_error *err) {
    uint32_t i;
    if (depth > RDX_QK_MAX_NESTING) {
        rdx_qk_set_error(err, "quack wire logical type exceeds nesting limit");
        return 0;
    }
    rdx_qk_write_field(w, 100);
    rdx_qk_write_uleb(w, t->id);
    if (rdx_qk_type_needs_info(t)) {
        rdx_qk_write_field(w, 101);
        rdx_qk_write_u8(w, 1); /* type_info present */
        switch (t->id) {
        case RDX_QK_LTYPE_DECIMAL:
            rdx_qk_write_field(w, 100);
            rdx_qk_write_uleb(w, RDX_QK_XINFO_DECIMAL);
            if (t->width) {
                rdx_qk_write_field(w, 200);
                rdx_qk_write_uleb(w, t->width);
            }
            if (t->scale) {
                rdx_qk_write_field(w, 201);
                rdx_qk_write_uleb(w, t->scale);
            }
            break;
        case RDX_QK_LTYPE_LIST:
        case RDX_QK_LTYPE_MAP:
            /* MAP serializes as LIST_TYPE_INFO over its STRUCT(key, value)
             * entry type, matching DuckDB's internal representation. */
            if (t->nchildren != 1) {
                rdx_qk_set_error(err, "LIST/MAP logical type requires exactly one child");
                return 0;
            }
            rdx_qk_write_field(w, 100);
            rdx_qk_write_uleb(w, RDX_QK_XINFO_LIST);
            rdx_qk_write_field(w, 200);
            if (!rdx_qk_type_encode_depth(w, t->children[0], depth + 1, err)) return 0;
            break;
        case RDX_QK_LTYPE_STRUCT:
        case RDX_QK_LTYPE_UNION:
            rdx_qk_write_field(w, 100);
            rdx_qk_write_uleb(w, RDX_QK_XINFO_STRUCT);
            rdx_qk_write_field(w, 200);
            rdx_qk_write_uleb(w, t->nchildren);
            for (i = 0; i < t->nchildren; i++) {
                const char *name = (t->names && t->names[i]) ? t->names[i] : "";
                if (!rdx_qk_child_pair_encode(w, name, t->children[i], depth + 1, err)) return 0;
            }
            break;
        case RDX_QK_LTYPE_ENUM:
            rdx_qk_write_field(w, 100);
            rdx_qk_write_uleb(w, RDX_QK_XINFO_ENUM);
            rdx_qk_write_field(w, 200);
            rdx_qk_write_uleb(w, t->enum_count);
            rdx_qk_write_field(w, 201);
            rdx_qk_write_uleb(w, t->enum_count);
            for (i = 0; i < t->enum_count; i++) {
                const char *label = t->enum_labels[i] ? t->enum_labels[i] : "";
                rdx_qk_write_string(w, label, strlen(label));
            }
            break;
        case RDX_QK_LTYPE_ARRAY:
            if (t->nchildren != 1) {
                rdx_qk_set_error(err, "ARRAY logical type requires exactly one child");
                return 0;
            }
            rdx_qk_write_field(w, 100);
            rdx_qk_write_uleb(w, RDX_QK_XINFO_ARRAY);
            rdx_qk_write_field(w, 200);
            if (!rdx_qk_type_encode_depth(w, t->children[0], depth + 1, err)) return 0;
            if (t->array_size) {
                rdx_qk_write_field(w, 201);
                rdx_qk_write_uleb(w, t->array_size);
            }
            break;
        default:
            rdx_qk_set_error(err, "internal error: unexpected extra type info");
            return 0;
        }
        rdx_qk_write_object_end(w); /* end type_info object */
    }
    rdx_qk_write_object_end(w); /* end LogicalType object */
    return 1;
}

int rdx_qk_type_encode(rdx_qk_writer *w, const rdx_qk_type *t, rdx_qk_error *err) {
    return rdx_qk_type_encode_depth(w, t, 0, err);
}

static int rdx_qk_type_decode_depth(rdx_qk_reader *r, rdx_qk_type **out,
                                    unsigned depth, rdx_qk_error *err);

static int rdx_qk_child_pair_decode(rdx_qk_reader *r, char **name_out, rdx_qk_type **type_out,
                                    unsigned depth, rdx_qk_error *err) {
    uint16_t field;
    const uint8_t *ptr;
    uint64_t len;
    int seen_name = 0, seen_type = 0;
    *name_out = NULL;
    *type_out = NULL;
    for (;;) {
        if (!rdx_qk_read_field(r, &field, err)) goto fail;
        if (field == RDX_QK_OBJECT_END) break;
        switch (field) {
        case 0:
            if (seen_name) {
                rdx_qk_set_error(err, "duplicate name in struct member pair");
                goto fail;
            }
            seen_name = 1;
            if (!rdx_qk_read_string(r, &ptr, &len, err)) goto fail;
            *name_out = rdx_qk_strdup_n((const char *)ptr, (size_t)len);
            if (!*name_out) {
                rdx_qk_set_error(err, "out of memory decoding struct member name");
                goto fail;
            }
            break;
        case 1:
            if (seen_type) {
                rdx_qk_set_error(err, "duplicate type in struct member pair");
                goto fail;
            }
            seen_type = 1;
            if (!rdx_qk_type_decode_depth(r, type_out, depth, err)) goto fail;
            break;
        default:
            rdx_qk_set_error(err, "unexpected field in struct member pair");
            goto fail;
        }
    }
    if (!*type_out) {
        rdx_qk_set_error(err, "struct member pair is missing its type");
        goto fail;
    }
    if (!*name_out) {
        *name_out = rdx_qk_strdup_n("", 0);
        if (!*name_out) goto fail;
    }
    return 1;
fail:
    free(*name_out);
    rdx_qk_type_free(*type_out);
    *name_out = NULL;
    *type_out = NULL;
    return 0;
}

static int rdx_qk_type_info_decode(rdx_qk_reader *r, rdx_qk_type *t,
                                   unsigned depth, rdx_qk_error *err) {
    uint16_t field;
    uint64_t value;
    const uint8_t *ptr;
    uint64_t len;
    uint64_t i, count;
    uint32_t seen = 0; /* reject duplicate type-info fields */
    for (;;) {
        if (!rdx_qk_read_field(r, &field, err)) return 0;
        if (field == RDX_QK_OBJECT_END) return 1;
        /* A duplicate field 200/201 would re-add children or overwrite the enum
         * label / decimal-width allocation without freeing the first (a C heap
         * leak), or mutate a width/scale; reject duplicates. */
        if (field == 100 || field == 101 || field == 103 || field == 200 || field == 201) {
            uint32_t bit = field < 200 ? (1u << (field - 100)) : (1u << (field - 200 + 5));
            if (seen & bit) {
                rdx_qk_set_error(err, "duplicate field in type info object");
                return 0;
            }
            seen |= bit;
        }
        switch (field) {
        case 100: /* extra info kind: validated against the logical id */
            if (!rdx_qk_read_uleb(r, &value, err)) return 0;
            break;
        case 101: /* alias */
            if (!rdx_qk_read_string(r, &ptr, &len, err)) return 0;
            break;
        case 103: /* extension info pointer */
            {
                uint8_t present;
                if (!rdx_qk_read_u8(r, &present, err)) return 0;
                if (present) {
                    rdx_qk_set_error(err, "extension type info is not supported on the Rducks wire");
                    return 0;
                }
            }
            break;
        case 200:
            switch (t->id) {
            case RDX_QK_LTYPE_DECIMAL:
                if (!rdx_qk_read_uleb(r, &value, err)) return 0;
                if (value > 38) {
                    rdx_qk_set_error(err, "decimal width exceeds 38");
                    return 0;
                }
                t->width = (uint8_t)value;
                break;
            case RDX_QK_LTYPE_LIST:
            case RDX_QK_LTYPE_MAP:
            case RDX_QK_LTYPE_ARRAY: {
                rdx_qk_type *child = NULL;
                if (!rdx_qk_type_decode_depth(r, &child, depth + 1, err)) return 0;
                if (!rdx_qk_type_add_child(t, child, "child")) {
                    rdx_qk_type_free(child);
                    rdx_qk_set_error(err, "out of memory decoding nested type");
                    return 0;
                }
                break;
            }
            case RDX_QK_LTYPE_STRUCT:
            case RDX_QK_LTYPE_UNION:
                if (!rdx_qk_read_uleb(r, &count, err)) return 0;
                if (count > RDX_QK_MAX_COLUMNS) {
                    rdx_qk_set_error(err, "struct member count exceeds limit");
                    return 0;
                }
                for (i = 0; i < count; i++) {
                    char *name = NULL;
                    rdx_qk_type *child = NULL;
                    if (!rdx_qk_child_pair_decode(r, &name, &child, depth + 1, err)) return 0;
                    if (!rdx_qk_type_add_child(t, child, name)) {
                        free(name);
                        rdx_qk_type_free(child);
                        rdx_qk_set_error(err, "out of memory decoding struct members");
                        return 0;
                    }
                    free(name);
                }
                break;
            case RDX_QK_LTYPE_ENUM:
                if (!rdx_qk_read_uleb(r, &value, err)) return 0;
                if (value > RDX_QK_MAX_ENUM_VALUES) {
                    rdx_qk_set_error(err, "enum dictionary size exceeds limit");
                    return 0;
                }
                t->enum_count = (uint32_t)value;
                break;
            default:
                rdx_qk_set_error(err, "unexpected field 200 in type info");
                return 0;
            }
            break;
        case 201:
            switch (t->id) {
            case RDX_QK_LTYPE_DECIMAL:
                if (!rdx_qk_read_uleb(r, &value, err)) return 0;
                if (value > 38) {
                    rdx_qk_set_error(err, "decimal scale exceeds 38");
                    return 0;
                }
                t->scale = (uint8_t)value;
                break;
            case RDX_QK_LTYPE_ARRAY:
                if (!rdx_qk_read_uleb(r, &value, err)) return 0;
                if (value > UINT32_MAX) {
                    rdx_qk_set_error(err, "array size exceeds limit");
                    return 0;
                }
                t->array_size = (uint32_t)value;
                break;
            case RDX_QK_LTYPE_ENUM: {
                uint64_t n;
                if (!rdx_qk_read_uleb(r, &n, err)) return 0;
                if (t->enum_count && n != t->enum_count) {
                    rdx_qk_set_error(err, "enum values list disagrees with values_count");
                    return 0;
                }
                if (n > RDX_QK_MAX_ENUM_VALUES) {
                    rdx_qk_set_error(err, "enum dictionary size exceeds limit");
                    return 0;
                }
                t->enum_count = (uint32_t)n;
                t->enum_labels = (char **)calloc((size_t)n ? (size_t)n : 1, sizeof(char *));
                if (!t->enum_labels) {
                    rdx_qk_set_error(err, "out of memory decoding enum labels");
                    return 0;
                }
                for (i = 0; i < n; i++) {
                    if (!rdx_qk_read_string(r, &ptr, &len, err)) return 0;
                    t->enum_labels[i] = rdx_qk_strdup_n((const char *)ptr, (size_t)len);
                    if (!t->enum_labels[i]) {
                        rdx_qk_set_error(err, "out of memory decoding enum labels");
                        return 0;
                    }
                }
                break;
            }
            default:
                rdx_qk_set_error(err, "unexpected field 201 in type info");
                return 0;
            }
            break;
        default:
            rdx_qk_set_error(err, "unknown field in type info object");
            return 0;
        }
    }
}

static int rdx_qk_type_decode_depth(rdx_qk_reader *r, rdx_qk_type **out,
                                    unsigned depth, rdx_qk_error *err) {
    rdx_qk_type *t = NULL;
    uint16_t field;
    uint64_t value;
    int seen_id = 0;
    int seen_info = 0;
    if (depth > RDX_QK_MAX_NESTING) {
        rdx_qk_set_error(err, "quack wire logical type exceeds nesting limit");
        return 0;
    }
    t = rdx_qk_type_new(0);
    if (!t) {
        rdx_qk_set_error(err, "out of memory decoding logical type");
        return 0;
    }
    for (;;) {
        if (!rdx_qk_read_field(r, &field, err)) goto fail;
        if (field == RDX_QK_OBJECT_END) break;
        switch (field) {
        case 100:
            if (seen_id) {
                rdx_qk_set_error(err, "duplicate type id in logical type object");
                goto fail;
            }
            if (!rdx_qk_read_uleb(r, &value, err)) goto fail;
            t->id = (uint32_t)value;
            seen_id = 1;
            break;
        case 101: {
            uint8_t present;
            if (!seen_id) {
                rdx_qk_set_error(err, "logical type info precedes its type id");
                goto fail;
            }
            if (seen_info) {
                rdx_qk_set_error(err, "duplicate type info in logical type object");
                goto fail;
            }
            seen_info = 1;
            if (!rdx_qk_read_u8(r, &present, err)) goto fail;
            if (present) {
                if (!rdx_qk_type_info_decode(r, t, depth, err)) goto fail;
            }
            break;
        }
        default:
            rdx_qk_set_error(err, "unknown field in logical type object");
            goto fail;
        }
    }
    if (!seen_id) {
        rdx_qk_set_error(err, "logical type object is missing its id");
        goto fail;
    }
    *out = t;
    return 1;
fail:
    rdx_qk_type_free(t);
    return 0;
}

int rdx_qk_type_decode(rdx_qk_reader *r, rdx_qk_type **out, rdx_qk_error *err) {
    return rdx_qk_type_decode_depth(r, out, 0, err);
}

/* ---------------- vector codec ---------------- */

static int rdx_qk_vector_encode_depth(rdx_qk_writer *w, const rdx_qk_vector *v,
                                      unsigned depth, rdx_qk_error *err);

static int rdx_qk_vector_is_varlen(const rdx_qk_type *t) {
    return t->id == RDX_QK_LTYPE_VARCHAR || t->id == RDX_QK_LTYPE_BLOB ||
           t->id == RDX_QK_LTYPE_BIT;
}

static int rdx_qk_vector_encode_depth(rdx_qk_writer *w, const rdx_qk_vector *v,
                                      unsigned depth, rdx_qk_error *err) {
    const rdx_qk_type *t = v->type;
    uint64_t row;
    uint32_t i;
    if (depth > RDX_QK_MAX_NESTING) {
        rdx_qk_set_error(err, "quack wire vector exceeds nesting limit");
        return 0;
    }
    /* field 90 omitted: flat vector */
    rdx_qk_write_field(w, 100);
    rdx_qk_write_u8(w, v->has_validity ? 1 : 0);
    if (v->has_validity) {
        rdx_qk_write_field(w, 101);
        rdx_qk_write_data(w, v->validity, rdx_qk_validity_bytes(v->rows));
    }
    if (rdx_qk_vector_is_varlen(t)) {
        if (!v->str_offsets) {
            rdx_qk_set_error(err, "varlen vector is missing its string storage");
            return 0;
        }
        rdx_qk_write_field(w, 102);
        rdx_qk_write_uleb(w, v->rows); /* list count: one string per row */
        for (row = 0; row < v->rows; row++) {
            uint64_t start = v->str_offsets[row];
            uint64_t end = v->str_offsets[row + 1];
            if (end < start || end > v->str_pool_size) {
                rdx_qk_set_error(err, "varlen vector offsets are inconsistent");
                return 0;
            }
            rdx_qk_write_string(w, (const char *)(v->str_pool + start), (size_t)(end - start));
        }
    } else if (t->id == RDX_QK_LTYPE_STRUCT || t->id == RDX_QK_LTYPE_UNION) {
        rdx_qk_write_field(w, 103);
        rdx_qk_write_uleb(w, v->nchildren);
        for (i = 0; i < v->nchildren; i++) {
            if (!rdx_qk_vector_encode_depth(w, v->children[i], depth + 1, err)) return 0;
            rdx_qk_write_object_end(w);
        }
    } else if (t->id == RDX_QK_LTYPE_LIST || t->id == RDX_QK_LTYPE_MAP) {
        if (!v->list_offsets || v->nchildren != 1) {
            rdx_qk_set_error(err, "list vector is missing its entries or child");
            return 0;
        }
        rdx_qk_write_field(w, 104);
        rdx_qk_write_uleb(w, v->list_child_rows);
        rdx_qk_write_field(w, 105);
        rdx_qk_write_uleb(w, v->rows);
        for (row = 0; row < v->rows; row++) {
            rdx_qk_write_field(w, 100);
            rdx_qk_write_uleb(w, v->list_offsets[row]);
            rdx_qk_write_field(w, 101);
            rdx_qk_write_uleb(w, v->list_lengths[row]);
            rdx_qk_write_object_end(w);
        }
        rdx_qk_write_field(w, 106);
        if (!rdx_qk_vector_encode_depth(w, v->children[0], depth + 1, err)) return 0;
        rdx_qk_write_object_end(w);
    } else if (t->id == RDX_QK_LTYPE_ARRAY) {
        if (v->nchildren != 1) {
            rdx_qk_set_error(err, "array vector is missing its child");
            return 0;
        }
        rdx_qk_write_field(w, 103);
        rdx_qk_write_uleb(w, t->array_size);
        rdx_qk_write_field(w, 104);
        if (!rdx_qk_vector_encode_depth(w, v->children[0], depth + 1, err)) return 0;
        rdx_qk_write_object_end(w);
    } else {
        size_t width = rdx_qk_type_fixed_width(t);
        if (width == 0 || !v->data) {
            rdx_qk_set_error(err, "fixed-width vector is missing its data payload");
            return 0;
        }
        if (v->data_size != width * (size_t)v->rows) {
            rdx_qk_set_error(err, "fixed-width vector payload size mismatch");
            return 0;
        }
        rdx_qk_write_field(w, 102);
        rdx_qk_write_data(w, v->data, v->data_size);
    }
    return 1;
}

static int rdx_qk_vector_decode_depth(rdx_qk_reader *r, const rdx_qk_type *t, uint64_t rows,
                                      rdx_qk_vector **out, unsigned depth, rdx_qk_error *err) {
    rdx_qk_vector *v = NULL;
    uint16_t field;
    uint64_t value, row;
    const uint8_t *ptr;
    uint64_t len;
    uint32_t seen_fields = 0; /* bit (field - 90) set once a payload field is read */
    if (depth > RDX_QK_MAX_NESTING) {
        rdx_qk_set_error(err, "quack wire vector exceeds nesting limit");
        return 0;
    }
    v = rdx_qk_vector_new(t, rows);
    if (!v) {
        rdx_qk_set_error(err, "out of memory decoding vector");
        return 0;
    }
    for (;;) {
        if (!rdx_qk_read_field(r, &field, err)) goto fail;
        if (field == RDX_QK_OBJECT_END) break;
        /* Each payload field may appear at most once per vector object. A
         * duplicate would overwrite an already-allocated buffer/child pointer
         * (a C heap leak) and could mutate cardinality after dependent fields
         * were decoded; reject malformed payloads instead. */
        if (field >= 90 && field <= 106) {
            uint32_t bit = 1u << (field - 90);
            if (seen_fields & bit) {
                rdx_qk_set_error(err, "duplicate field in quack vector object");
                goto fail;
            }
            seen_fields |= bit;
        }
        switch (field) {
        case 90: /* vector_type */
            if (!rdx_qk_read_uleb(r, &value, err)) goto fail;
            if (value != 0) {
                rdx_qk_set_error(err, "non-flat quack vectors (constant/dictionary/sequence/FSST) are not supported yet");
                goto fail;
            }
            break;
        case 99: /* geometry format */
            if (!rdx_qk_read_uleb(r, &value, err)) goto fail;
            break;
        case 100: { /* has_validity */
            uint8_t flag;
            if (!rdx_qk_read_u8(r, &flag, err)) goto fail;
            v->has_validity = flag ? 1 : 0;
            break;
        }
        case 101: { /* validity mask */
            size_t expected = rdx_qk_validity_bytes(rows);
            if (!rdx_qk_read_data(r, &ptr, &len, err)) goto fail;
            if ((size_t)len < expected) {
                rdx_qk_set_error(err, "validity mask is shorter than the row count requires");
                goto fail;
            }
            v->validity = (uint8_t *)malloc(expected ? expected : 1);
            if (!v->validity) {
                rdx_qk_set_error(err, "out of memory decoding validity mask");
                goto fail;
            }
            memcpy(v->validity, ptr, expected);
            v->has_validity = 1;
            break;
        }
        case 102: /* data */
            if (rdx_qk_vector_is_varlen(t)) {
                uint64_t count, total = 0;
                size_t fill = 0;
                if (!rdx_qk_read_uleb(r, &count, err)) goto fail;
                if (count != rows) {
                    rdx_qk_set_error(err, "varlen vector row payload count mismatch");
                    goto fail;
                }
                /* Two-pass: bound the pool by the remaining payload size. */
                if (!rdx_qk_vector_alloc_strings(v, r->size - r->pos)) {
                    rdx_qk_set_error(err, "out of memory decoding string vector");
                    goto fail;
                }
                for (row = 0; row < count; row++) {
                    if (!rdx_qk_read_string(r, &ptr, &len, err)) goto fail;
                    memcpy(v->str_pool + fill, ptr, (size_t)len);
                    v->str_offsets[row] = total;
                    fill += (size_t)len;
                    total += len;
                }
                v->str_offsets[count] = total;
                v->str_pool_size = (size_t)total;
            } else {
                size_t width = rdx_qk_type_fixed_width(t);
                if (width == 0) {
                    rdx_qk_set_error(err, "unexpected raw data payload for nested vector");
                    goto fail;
                }
                if (!rdx_qk_read_data(r, &ptr, &len, err)) goto fail;
                if ((uint64_t)width * rows != len) {
                    rdx_qk_set_error(err, "fixed-width vector payload size mismatch");
                    goto fail;
                }
                v->data = (uint8_t *)malloc((size_t)len ? (size_t)len : 1);
                if (!v->data) {
                    rdx_qk_set_error(err, "out of memory decoding vector payload");
                    goto fail;
                }
                memcpy(v->data, ptr, (size_t)len);
                v->data_size = (size_t)len;
            }
            break;
        case 103:
            if (t->id == RDX_QK_LTYPE_STRUCT || t->id == RDX_QK_LTYPE_UNION) {
                uint64_t count, i;
                if (!rdx_qk_read_uleb(r, &count, err)) goto fail;
                if (count != t->nchildren) {
                    rdx_qk_set_error(err, "struct vector child count disagrees with its type");
                    goto fail;
                }
                v->children = (rdx_qk_vector **)calloc((size_t)count ? (size_t)count : 1, sizeof(*v->children));
                if (!v->children) {
                    rdx_qk_set_error(err, "out of memory decoding struct children");
                    goto fail;
                }
                for (i = 0; i < count; i++) {
                    if (!rdx_qk_vector_decode_depth(r, t->children[i], rows, &v->children[i], depth + 1, err)) goto fail;
                    v->nchildren = (uint32_t)(i + 1);
                }
            } else if (t->id == RDX_QK_LTYPE_ARRAY) {
                if (!rdx_qk_read_uleb(r, &value, err)) goto fail;
                if (value != t->array_size) {
                    rdx_qk_set_error(err, "array vector size disagrees with its type");
                    goto fail;
                }
            } else {
                rdx_qk_set_error(err, "unexpected children field for this vector type");
                goto fail;
            }
            break;
        case 104:
            if (t->id == RDX_QK_LTYPE_LIST || t->id == RDX_QK_LTYPE_MAP) {
                if (!rdx_qk_read_uleb(r, &value, err)) goto fail;
                if (value > RDX_QK_MAX_ROWS) {
                    rdx_qk_set_error(err, "list child cardinality exceeds limit");
                    goto fail;
                }
                v->list_child_rows = value;
            } else if (t->id == RDX_QK_LTYPE_ARRAY) {
                uint64_t child_rows = (uint64_t)t->array_size * rows;
                v->children = (rdx_qk_vector **)calloc(1, sizeof(*v->children));
                if (!v->children) {
                    rdx_qk_set_error(err, "out of memory decoding array child");
                    goto fail;
                }
                if (t->nchildren != 1) {
                    rdx_qk_set_error(err, "array type is missing its child");
                    goto fail;
                }
                if (!rdx_qk_vector_decode_depth(r, t->children[0], child_rows, &v->children[0], depth + 1, err)) goto fail;
                v->nchildren = 1;
            } else {
                rdx_qk_set_error(err, "unexpected list-size field for this vector type");
                goto fail;
            }
            break;
        case 105: { /* list entries */
            uint64_t count, i;
            if (t->id != RDX_QK_LTYPE_LIST && t->id != RDX_QK_LTYPE_MAP) {
                rdx_qk_set_error(err, "unexpected list entries for this vector type");
                goto fail;
            }
            if (!rdx_qk_read_uleb(r, &count, err)) goto fail;
            if (count != rows) {
                rdx_qk_set_error(err, "list entries count disagrees with row count");
                goto fail;
            }
            if (!rdx_qk_vector_alloc_list(v, v->list_child_rows)) {
                rdx_qk_set_error(err, "out of memory decoding list entries");
                goto fail;
            }
            for (i = 0; i < count; i++) {
                uint16_t efield;
                int seen_off = 0, seen_len = 0;
                for (;;) {
                    if (!rdx_qk_read_field(r, &efield, err)) goto fail;
                    if (efield == RDX_QK_OBJECT_END) break;
                    if (efield == 100) {
                        if (seen_off) { rdx_qk_set_error(err, "duplicate offset in list entry object"); goto fail; }
                        seen_off = 1;
                        if (!rdx_qk_read_uleb(r, &v->list_offsets[i], err)) goto fail;
                    } else if (efield == 101) {
                        if (seen_len) { rdx_qk_set_error(err, "duplicate length in list entry object"); goto fail; }
                        seen_len = 1;
                        if (!rdx_qk_read_uleb(r, &v->list_lengths[i], err)) goto fail;
                    } else {
                        rdx_qk_set_error(err, "unknown field in list entry object");
                        goto fail;
                    }
                }
                /* An entry missing offset or length would silently default to
                 * zero, dropping rows; require both. */
                if (!seen_off || !seen_len) {
                    rdx_qk_set_error(err, "list entry object is missing its offset or length");
                    goto fail;
                }
            }
            break;
        }
        case 106: { /* list child vector */
            if (t->id != RDX_QK_LTYPE_LIST && t->id != RDX_QK_LTYPE_MAP) {
                rdx_qk_set_error(err, "unexpected list child for this vector type");
                goto fail;
            }
            if (t->nchildren != 1) {
                rdx_qk_set_error(err, "list type is missing its child");
                goto fail;
            }
            v->children = (rdx_qk_vector **)calloc(1, sizeof(*v->children));
            if (!v->children) {
                rdx_qk_set_error(err, "out of memory decoding list child");
                goto fail;
            }
            if (!rdx_qk_vector_decode_depth(r, t->children[0], v->list_child_rows, &v->children[0], depth + 1, err)) goto fail;
            v->nchildren = 1;
            break;
        }
        default:
            rdx_qk_set_error(err, "unknown field in vector object");
            goto fail;
        }
    }
    /* A vector that advertises validity (field 100 flag set) must carry a decoded
     * validity mask (field 101); otherwise rdx_qk_vector_row_is_valid would read
     * a NULL mask. The flag and the mask field both set has_validity, so this
     * catches a payload that sets the flag but omits the mask. */
    if (v->has_validity && v->rows > 0 && !v->validity) {
        rdx_qk_set_error(err, "vector advertises validity but is missing its mask");
        goto fail;
    }
    /* Reject incomplete vector objects before publishing them. A malformed
     * payload (e.g. from an external ipc endpoint) may omit the payload field for
     * the vector's logical type, leaving the buffers NULL; R materialization and
     * the native writeback would then dereference NULL or read past the child.
     * Validate per-type completeness and the LIST/MAP child bounds here. */
    if (t->id == RDX_QK_LTYPE_STRUCT || t->id == RDX_QK_LTYPE_UNION) {
        uint32_t i;
        if (v->nchildren != t->nchildren || (t->nchildren && !v->children)) {
            rdx_qk_set_error(err, "struct/union vector is missing child columns");
            goto fail;
        }
        for (i = 0; i < v->nchildren; i++) {
            if (!v->children[i]) {
                rdx_qk_set_error(err, "struct/union vector has a missing child column");
                goto fail;
            }
        }
    } else if (t->id == RDX_QK_LTYPE_LIST || t->id == RDX_QK_LTYPE_MAP) {
        uint64_t i;
        if (v->nchildren != 1 || !v->children || !v->children[0]) {
            rdx_qk_set_error(err, "list/map vector is missing its child column");
            goto fail;
        }
        /* The child must have been decoded with exactly the declared cardinality.
         * If the child-size and child-vector fields arrive out of order (or a
         * field is duplicated to mutate the cardinality after the child decode),
         * these disagree and the entry bounds would reference rows the child does
         * not actually hold. */
        if (v->children[0]->rows != v->list_child_rows) {
            rdx_qk_set_error(err, "list/map child row count disagrees with the declared cardinality");
            goto fail;
        }
        if (v->rows > 0 && (!v->list_offsets || !v->list_lengths)) {
            rdx_qk_set_error(err, "list/map vector is missing offsets or lengths");
            goto fail;
        }
        for (i = 0; i < v->rows; i++) {
            uint64_t off = v->list_offsets[i];
            uint64_t len = v->list_lengths[i];
            if (off > v->list_child_rows || len > v->list_child_rows - off) {
                rdx_qk_set_error(err, "list entry references rows beyond the child vector");
                goto fail;
            }
        }
    } else if (t->id == RDX_QK_LTYPE_ARRAY) {
        if (v->nchildren != 1 || !v->children || !v->children[0]) {
            rdx_qk_set_error(err, "array vector is missing its child column");
            goto fail;
        }
    } else if (rdx_qk_vector_is_varlen(t)) {
        if (v->rows > 0 && !v->str_offsets) {
            rdx_qk_set_error(err, "varlen vector is missing its string offsets");
            goto fail;
        }
    } else {
        size_t width = rdx_qk_type_fixed_width(t);
        if (width == 0) {
            rdx_qk_set_error(err, "vector has an unsupported logical type");
            goto fail;
        }
        if (v->rows > 0 && (!v->data || v->data_size != width * (size_t)v->rows)) {
            rdx_qk_set_error(err, "fixed-width vector is missing or wrong-sized data");
            goto fail;
        }
    }
    *out = v;
    return 1;
fail:
    rdx_qk_vector_free(v);
    return 0;
}

/* ---------------- DataChunk codec ---------------- */

int rdx_qk_chunk_encode(rdx_qk_writer *w, const rdx_qk_chunk *c, rdx_qk_error *err) {
    uint32_t i;
    rdx_qk_write_field(w, 100);
    rdx_qk_write_uleb(w, c->rows);
    rdx_qk_write_field(w, 101);
    rdx_qk_write_uleb(w, c->ncolumns);
    for (i = 0; i < c->ncolumns; i++) {
        if (!rdx_qk_type_encode(w, c->types[i], err)) return 0;
    }
    rdx_qk_write_field(w, 102);
    rdx_qk_write_uleb(w, c->ncolumns);
    for (i = 0; i < c->ncolumns; i++) {
        if (!rdx_qk_vector_encode_depth(w, c->columns[i], 0, err)) return 0;
        rdx_qk_write_object_end(w);
    }
    rdx_qk_write_object_end(w);
    if (w->oom) {
        rdx_qk_set_error(err, "out of memory encoding quack chunk");
        return 0;
    }
    return 1;
}

int rdx_qk_chunk_decode(rdx_qk_reader *r, rdx_qk_chunk **out, rdx_qk_error *err) {
    rdx_qk_chunk *c = NULL;
    uint16_t field;
    uint64_t rows = 0, value, i;
    int seen_rows = 0, seen_types = 0, seen_columns = 0;
    rdx_qk_type **types = NULL;
    uint64_t ntypes = 0;
    for (;;) {
        if (!rdx_qk_read_field(r, &field, err)) goto fail;
        if (field == RDX_QK_OBJECT_END) break;
        switch (field) {
        case 100:
            if (seen_rows) {
                rdx_qk_set_error(err, "duplicate row-count field in quack chunk object");
                goto fail;
            }
            if (!rdx_qk_read_uleb(r, &rows, err)) goto fail;
            if (rows > RDX_QK_MAX_ROWS) {
                rdx_qk_set_error(err, "quack chunk row count exceeds limit");
                goto fail;
            }
            seen_rows = 1;
            break;
        case 101:
            if (seen_types) {
                rdx_qk_set_error(err, "duplicate types field in quack chunk object");
                goto fail;
            }
            seen_types = 1;
            if (!rdx_qk_read_uleb(r, &value, err)) goto fail;
            if (value > RDX_QK_MAX_COLUMNS) {
                rdx_qk_set_error(err, "quack chunk column count exceeds limit");
                goto fail;
            }
            ntypes = value;
            types = (rdx_qk_type **)calloc((size_t)ntypes ? (size_t)ntypes : 1, sizeof(*types));
            if (!types) {
                rdx_qk_set_error(err, "out of memory decoding chunk types");
                goto fail;
            }
            for (i = 0; i < ntypes; i++) {
                if (!rdx_qk_type_decode(r, &types[i], err)) goto fail;
            }
            break;
        case 102:
            if (seen_columns) {
                rdx_qk_set_error(err, "duplicate columns field in quack chunk object");
                goto fail;
            }
            seen_columns = 1;
            if (!seen_rows || !types) {
                rdx_qk_set_error(err, "quack chunk columns precede rows or types");
                goto fail;
            }
            if (!rdx_qk_read_uleb(r, &value, err)) goto fail;
            if (value != ntypes) {
                rdx_qk_set_error(err, "quack chunk column count disagrees with its types");
                goto fail;
            }
            c = rdx_qk_chunk_new(rows, (uint32_t)ntypes);
            if (!c) {
                rdx_qk_set_error(err, "out of memory decoding chunk");
                goto fail;
            }
            for (i = 0; i < ntypes; i++) {
                c->types[i] = types[i];
                types[i] = NULL;
            }
            free(types);
            types = NULL;
            for (i = 0; i < c->ncolumns; i++) {
                if (!rdx_qk_vector_decode_depth(r, c->types[i], rows, &c->columns[i], 0, err)) goto fail;
            }
            break;
        default:
            rdx_qk_set_error(err, "unknown field in quack chunk object");
            goto fail;
        }
    }
    if (!c) {
        rdx_qk_set_error(err, "quack chunk payload is missing its columns");
        goto fail;
    }
    *out = c;
    return 1;
fail:
    if (types) {
        for (i = 0; i < ntypes; i++) rdx_qk_type_free(types[i]);
        free(types);
    }
    rdx_qk_chunk_free(c);
    return 0;
}
