/* Rducks Quack wire core.
 *
 * Standalone C implementation of the DuckDB BinarySerializer subset needed to
 * encode and decode DataChunk payloads (the "Quack" wire format), plus the
 * LogicalType objects embedded in every chunk. This translation unit has no R
 * and no DuckDB dependency so the identical code compiles into:
 *
 *   - the Rducks R package shared object (main-thread SEXP adapters live in
 *     quack_codec.c);
 *   - the Rducks DuckDB extension (DuckDB-vector adapters live in
 *     tools/ext/src/rducks_ripc.c), where encode/decode may run on DuckDB
 *     execution threads because nothing here touches the R API.
 *
 * Wire grammar (DuckDB BinarySerializer, serialization_compatibility v7):
 *
 *   object   := (field_id payload)* 0xffff
 *   field_id := uint16 little-endian
 *   uint     := unsigned LEB128
 *   sint     := signed LEB128
 *   string   := uint byte-length, raw bytes
 *   data     := uint byte-length, raw bytes
 *   list<T>  := uint count, count * T
 *   ptr<T>   := bool present-byte, object(T) when present
 *
 * DataChunk object: field 100 rows (uint32 as uint), field 101 list of
 * LogicalType objects, field 102 list of Vector objects.
 *
 * Flat Vector object: field 90 vector_type (absent == FLAT), field 100
 * has_validity (bool byte), field 101 validity raw bytes (DuckDB uint64-word
 * mask), field 102 data (raw bytes for fixed-width physical types, or a list
 * of per-row strings for VARCHAR/BLOB), field 103 struct children (list of
 * vectors), field 104 list child size / 103 array size, field 105 list
 * entries (objects with field 100 offset, field 101 length), field 106 list
 * child vector. Non-flat vector types (constant, dictionary, sequence, FSST)
 * are rejected by this implementation until byte fixtures pin them.
 *
 * LogicalType object: field 100 id (uint), field 101 optional ExtraTypeInfo
 * pointer. ExtraTypeInfo object: field 100 extra-info kind (uint), field 101
 * alias (default-omitted string), then kind-specific fields: DECIMAL(2) 200
 * width / 201 scale; LIST(4) 200 child type; STRUCT(5) 200 child list of
 * (name, type) pairs; ENUM(6) 200 values_count / 201 value strings; ARRAY(9)
 * 200 child type / 201 size.
 *
 * std::pair serialization follows DuckDB's generated code: an object with
 * field 0 = first and field 1 = second. Pin this against upstream byte
 * fixtures before declaring cross-implementation compatibility.
 */

#ifndef RDUCKS_QUACK_CORE_H
#define RDUCKS_QUACK_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RDX_QK_OBJECT_END 0xffffu

/* DuckDB LogicalTypeId values used on the wire. */
enum {
    RDX_QK_LTYPE_BOOLEAN = 10,
    RDX_QK_LTYPE_TINYINT = 11,
    RDX_QK_LTYPE_SMALLINT = 12,
    RDX_QK_LTYPE_INTEGER = 13,
    RDX_QK_LTYPE_BIGINT = 14,
    RDX_QK_LTYPE_DATE = 15,
    RDX_QK_LTYPE_TIME = 16,
    RDX_QK_LTYPE_TIMESTAMP_SEC = 17,
    RDX_QK_LTYPE_TIMESTAMP_MS = 18,
    RDX_QK_LTYPE_TIMESTAMP = 19,
    RDX_QK_LTYPE_TIMESTAMP_NS = 20,
    RDX_QK_LTYPE_DECIMAL = 21,
    RDX_QK_LTYPE_FLOAT = 22,
    RDX_QK_LTYPE_DOUBLE = 23,
    RDX_QK_LTYPE_VARCHAR = 25,
    RDX_QK_LTYPE_BLOB = 26,
    RDX_QK_LTYPE_INTERVAL = 27,
    RDX_QK_LTYPE_UTINYINT = 28,
    RDX_QK_LTYPE_USMALLINT = 29,
    RDX_QK_LTYPE_UINTEGER = 30,
    RDX_QK_LTYPE_UBIGINT = 31,
    RDX_QK_LTYPE_TIMESTAMP_TZ = 32,
    RDX_QK_LTYPE_TIME_TZ = 34,
    RDX_QK_LTYPE_BIT = 36,
    RDX_QK_LTYPE_UHUGEINT = 49,
    RDX_QK_LTYPE_HUGEINT = 50,
    RDX_QK_LTYPE_UUID = 54,
    RDX_QK_LTYPE_STRUCT = 100,
    RDX_QK_LTYPE_LIST = 101,
    RDX_QK_LTYPE_MAP = 102,
    RDX_QK_LTYPE_ENUM = 104,
    RDX_QK_LTYPE_UNION = 107,
    RDX_QK_LTYPE_ARRAY = 108,
    RDX_QK_LTYPE_VARIANT = 109
};

/* ExtraTypeInfo kinds. */
enum {
    RDX_QK_XINFO_INVALID = 0,
    RDX_QK_XINFO_GENERIC = 1,
    RDX_QK_XINFO_DECIMAL = 2,
    RDX_QK_XINFO_STRING = 3,
    RDX_QK_XINFO_LIST = 4,
    RDX_QK_XINFO_STRUCT = 5,
    RDX_QK_XINFO_ENUM = 6,
    RDX_QK_XINFO_ARRAY = 9
};

typedef struct rdx_qk_error {
    char message[256];
} rdx_qk_error;

/* ---- recursive logical type tree ---- */

typedef struct rdx_qk_type {
    uint32_t id;          /* RDX_QK_LTYPE_* */
    uint8_t width;        /* decimal width */
    uint8_t scale;        /* decimal scale */
    uint32_t array_size;  /* ARRAY fixed size */
    uint32_t nchildren;   /* struct/map/union members, 1 for list/array */
    struct rdx_qk_type **children;
    char **names;         /* struct/union member names, may be NULL */
    uint32_t enum_count;
    char **enum_labels;   /* ENUM dictionary */
} rdx_qk_type;

rdx_qk_type *rdx_qk_type_new(uint32_t id);
void rdx_qk_type_free(rdx_qk_type *t);
int rdx_qk_type_add_child(rdx_qk_type *t, rdx_qk_type *child, const char *name);
int rdx_qk_type_set_enum_labels(rdx_qk_type *t, const char *const *labels, uint32_t n);
/* Physical byte width per row for fixed-width payloads; 0 for varlen/nested. */
size_t rdx_qk_type_fixed_width(const rdx_qk_type *t);
int rdx_qk_type_equal(const rdx_qk_type *a, const rdx_qk_type *b);

/* ---- recursive vector model ---- */

typedef struct rdx_qk_vector {
    const rdx_qk_type *type; /* borrowed */
    uint64_t rows;
    uint8_t has_validity;
    uint8_t *validity;       /* DuckDB mask words; ((rows+63)/64)*8 bytes when present */
    /* fixed-width payload */
    uint8_t *data;
    size_t data_size;
    /* varlen payload: per-row byte ranges into blob pool */
    uint64_t *str_offsets;   /* rows + 1 entries */
    uint8_t *str_pool;
    size_t str_pool_size;
    /* list payload */
    uint64_t *list_offsets;  /* rows entries */
    uint64_t *list_lengths;  /* rows entries */
    uint64_t list_child_rows;
    /* nested children: struct members, or single list/array child */
    uint32_t nchildren;
    struct rdx_qk_vector **children;
} rdx_qk_vector;

rdx_qk_vector *rdx_qk_vector_new(const rdx_qk_type *type, uint64_t rows);
void rdx_qk_vector_free(rdx_qk_vector *v);
int rdx_qk_vector_alloc_validity(rdx_qk_vector *v);
void rdx_qk_vector_set_null(rdx_qk_vector *v, uint64_t row);
int rdx_qk_vector_row_is_valid(const rdx_qk_vector *v, uint64_t row);
int rdx_qk_vector_alloc_fixed(rdx_qk_vector *v);
int rdx_qk_vector_alloc_strings(rdx_qk_vector *v, size_t pool_bytes);
int rdx_qk_vector_alloc_list(rdx_qk_vector *v, uint64_t child_rows);

typedef struct rdx_qk_chunk {
    uint64_t rows;
    uint32_t ncolumns;
    rdx_qk_type **types;     /* owned */
    rdx_qk_vector **columns; /* owned */
} rdx_qk_chunk;

rdx_qk_chunk *rdx_qk_chunk_new(uint64_t rows, uint32_t ncolumns);
void rdx_qk_chunk_free(rdx_qk_chunk *c);

/* ---- writer / reader ---- */

typedef struct rdx_qk_writer {
    uint8_t *data;
    size_t size;
    size_t cap;
    int oom;
} rdx_qk_writer;

void rdx_qk_writer_init(rdx_qk_writer *w);
void rdx_qk_writer_destroy(rdx_qk_writer *w);
/* Detach the buffer; caller frees. NULL on OOM. */
uint8_t *rdx_qk_writer_detach(rdx_qk_writer *w, size_t *size_out);

void rdx_qk_write_u8(rdx_qk_writer *w, uint8_t x);
void rdx_qk_write_bytes(rdx_qk_writer *w, const void *data, size_t n);
void rdx_qk_write_field(rdx_qk_writer *w, uint16_t field_id);
void rdx_qk_write_object_end(rdx_qk_writer *w);
void rdx_qk_write_uleb(rdx_qk_writer *w, uint64_t x);
void rdx_qk_write_sleb(rdx_qk_writer *w, int64_t x);
void rdx_qk_write_string(rdx_qk_writer *w, const char *s, size_t n);
void rdx_qk_write_data(rdx_qk_writer *w, const void *data, size_t n);

typedef struct rdx_qk_reader {
    const uint8_t *data;
    size_t size;
    size_t pos;
} rdx_qk_reader;

void rdx_qk_reader_init(rdx_qk_reader *r, const uint8_t *data, size_t size);
int rdx_qk_read_u8(rdx_qk_reader *r, uint8_t *out, rdx_qk_error *err);
int rdx_qk_read_field(rdx_qk_reader *r, uint16_t *out, rdx_qk_error *err);
int rdx_qk_read_uleb(rdx_qk_reader *r, uint64_t *out, rdx_qk_error *err);
int rdx_qk_read_sleb(rdx_qk_reader *r, int64_t *out, rdx_qk_error *err);
/* Borrowing reads: pointers reference the reader's buffer. */
int rdx_qk_read_string(rdx_qk_reader *r, const uint8_t **ptr, uint64_t *len, rdx_qk_error *err);
int rdx_qk_read_data(rdx_qk_reader *r, const uint8_t **ptr, uint64_t *len, rdx_qk_error *err);
int rdx_qk_skip_bytes(rdx_qk_reader *r, uint64_t n, rdx_qk_error *err);

/* ---- LogicalType codec ---- */

int rdx_qk_type_encode(rdx_qk_writer *w, const rdx_qk_type *t, rdx_qk_error *err);
int rdx_qk_type_decode(rdx_qk_reader *r, rdx_qk_type **out, rdx_qk_error *err);

/* ---- DataChunk codec ----
 *
 * Encodes/decodes the DataChunk object only (fields 100/101/102). Message
 * envelopes (header + body objects) are the transport's concern; the Rducks
 * NNG data plane sends one DataChunk object per task payload, prefixed by the
 * Rducks task envelope, not by the upstream Quack HTTP message header.
 */
int rdx_qk_chunk_encode(rdx_qk_writer *w, const rdx_qk_chunk *c, rdx_qk_error *err);
int rdx_qk_chunk_decode(rdx_qk_reader *r, rdx_qk_chunk **out, rdx_qk_error *err);

/* Limits applied while decoding untrusted payloads. */
#define RDX_QK_MAX_COLUMNS 65536u
#define RDX_QK_MAX_ROWS (1ull << 31)
#define RDX_QK_MAX_NESTING 64u
#define RDX_QK_MAX_ENUM_VALUES (1u << 24)

size_t rdx_qk_validity_bytes(uint64_t rows);

#ifdef __cplusplus
}
#endif

#endif /* RDUCKS_QUACK_CORE_H */
