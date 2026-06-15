/* Rducks quack codec R glue.
 *
 * Main-thread adapters between R storage columns and Quack DataChunk bytes,
 * built on the thread-safe pure-C core in quack_core.c. All functions here
 * run on the R main thread (package .Call interface, worker R processes, or
 * the extension's recorded R thread); everything below quack_core.h is free
 * of the R API and may run on DuckDB execution threads.
 *
 * R-side type spec (recursive list):
 *   list(id = integer(1), width = integer(1), scale = integer(1),
 *        array_size = integer(1), children = named list of specs,
 *        enum_labels = character())
 *
 * R-side column storage (recursive list):
 *   list(valid = logical(rows) | NULL, data = <storage>)
 * where <storage> per logical type id is:
 *   BOOLEAN                      logical(rows)
 *   TINYINT..INTEGER, U8/U16     integer(rows)
 *   UINTEGER                     double(rows)
 *   BIGINT/UBIGINT               character(rows)  decimal strings
 *   HUGEINT/UHUGEINT             character(rows)  decimal strings
 *   DECIMAL                      character(rows)  scaled-integer strings
 *   FLOAT/DOUBLE                 double(rows)
 *   DATE                         integer(rows)    days since epoch
 *   TIME/TIME_TZ/TIMESTAMP*      double(rows)     microseconds (|x| < 2^53)
 *   VARCHAR                      character(rows)
 *   BLOB                         list(rows) of raw or NULL
 *   UUID                         character(rows)  canonical hex
 *   ENUM                         integer(rows)    1-based codes
 *   INTERVAL                     list(months = integer, days = integer,
 *                                     micros = double)
 *   LIST/MAP                     list(offsets = double, lengths = double,
 *                                     child = <column>)
 *   ARRAY                        list(child = <column>)
 *   STRUCT/UNION                 unnamed list of <column>, one per member
 */

#include <string.h>
#include <stdlib.h>

#include <Rinternals.h>

#include "quack_core.h"

/* ---------------- small helpers ---------------- */

static void rdx_qkr_fail(rdx_qk_error *err, const char *fallback) {
    Rf_error("Rducks quack codec: %s", err && err->message[0] ? err->message : fallback);
}

static SEXP rdx_qkr_list_elt(SEXP x, const char *name) {
    SEXP names = Rf_getAttrib(x, R_NamesSymbol);
    R_xlen_t i;
    if (TYPEOF(x) != VECSXP || names == R_NilValue) return R_NilValue;
    for (i = 0; i < Rf_xlength(x); i++) {
        if (strcmp(CHAR(STRING_ELT(names, i)), name) == 0) return VECTOR_ELT(x, i);
    }
    return R_NilValue;
}

static int rdx_qkr_int_field(SEXP spec, const char *name, int fallback) {
    SEXP v = rdx_qkr_list_elt(spec, name);
    if (v == R_NilValue || Rf_xlength(v) < 1) return fallback;
    if (TYPEOF(v) == INTSXP) return INTEGER(v)[0] == NA_INTEGER ? fallback : INTEGER(v)[0];
    if (TYPEOF(v) == REALSXP) return ISNA(REAL(v)[0]) ? fallback : (int)REAL(v)[0];
    return fallback;
}

/* ---------------- BIT physical <-> rducks_bits ----------------
 * DuckDB stores BIT as a varlen blob whose first byte is the number of unused
 * padding bits in the most significant position, followed by MSB-first bit data.
 * The wire transports that physical form unchanged; the helpers below convert it
 * to/from the rducks_bits object (list(data = packed raw, length = bit count)),
 * matching the direct-path conversion in tools/ext/src/rducks_rc.c. */

/* Physical byte length needed for a bit string of bit_length bits. */
static size_t rdx_qkr_bit_physical_len(int bit_length) {
    return (size_t)(1 + (bit_length + 7) / 8);
}

/* rducks_bits SEXP -> DuckDB physical bytes written at dst (must hold
 * rdx_qkr_bit_physical_len). Returns the number of bytes written. */
static size_t rdx_qkr_bit_to_physical(SEXP value, unsigned char *dst) {
    SEXP data;
    int bit_length, padding, i;
    size_t len;
    if (TYPEOF(value) != VECSXP || XLENGTH(value) < 2) {
        Rf_error("Rducks quack codec: BIT rows must be rducks_bits objects or NULL");
    }
    data = VECTOR_ELT(value, 0);
    bit_length = Rf_asInteger(VECTOR_ELT(value, 1));
    if (TYPEOF(data) != RAWSXP || bit_length <= 0 || (R_xlen_t)bit_length > XLENGTH(data) * 8) {
        Rf_error("Rducks quack codec: rducks_bits object has invalid storage");
    }
    padding = (8 - (bit_length % 8)) % 8;
    len = rdx_qkr_bit_physical_len(bit_length);
    memset(dst, 0, len);
    dst[0] = (unsigned char)padding;
    for (i = 0; i < padding; i++) {
        dst[1] = (unsigned char)(dst[1] | (unsigned char)(1U << (7 - i)));
    }
    for (i = 0; i < bit_length; i++) {
        int src_byte = i / 8;
        int src_bit = i % 8;
        if ((RAW(data)[src_byte] >> (7 - src_bit)) & 1U) {
            int storage_bit = padding + i;
            int dst_byte = 1 + storage_bit / 8;
            int dst_bit = storage_bit % 8;
            dst[dst_byte] = (unsigned char)(dst[dst_byte] | (unsigned char)(1U << (7 - dst_bit)));
        }
    }
    return len;
}

/* DuckDB physical bytes -> rducks_bits SEXP (or R_NilValue for malformed). */
static SEXP rdx_qkr_bit_from_physical(const unsigned char *payload, size_t len) {
    int padding, bit_length, i;
    R_xlen_t nbytes;
    SEXP data, out, names, cls;
    if (len < 2) return R_NilValue;
    padding = payload[0];
    if (padding < 0 || padding > 7) return R_NilValue;
    bit_length = (int)((len - 1U) * 8U) - padding;
    if (bit_length <= 0) return R_NilValue;
    nbytes = (bit_length + 7) / 8;
    data = PROTECT(Rf_allocVector(RAWSXP, nbytes));
    memset(RAW(data), 0, (size_t)nbytes);
    for (i = 0; i < bit_length; i++) {
        int storage_bit = padding + i;
        int src_byte = 1 + storage_bit / 8;
        int src_bit = storage_bit % 8;
        if ((payload[src_byte] >> (7 - src_bit)) & 1U) {
            int dst_byte = i / 8;
            int dst_bit = i % 8;
            RAW(data)[dst_byte] = (Rbyte)(RAW(data)[dst_byte] | (Rbyte)(1U << (7 - dst_bit)));
        }
    }
    out = PROTECT(Rf_allocVector(VECSXP, 2));
    names = PROTECT(Rf_allocVector(STRSXP, 2));
    cls = PROTECT(Rf_mkString("rducks_bits"));
    SET_VECTOR_ELT(out, 0, data);
    SET_VECTOR_ELT(out, 1, Rf_ScalarInteger(bit_length));
    SET_STRING_ELT(names, 0, Rf_mkChar("data"));
    SET_STRING_ELT(names, 1, Rf_mkChar("length"));
    Rf_setAttrib(out, R_NamesSymbol, names);
    Rf_setAttrib(out, R_ClassSymbol, cls);
    UNPROTECT(4);
    return out;
}

/* ---------------- 64/128-bit decimal strings ---------------- */

typedef struct rdx_qkr_u128 {
    uint64_t lo;
    uint64_t hi;
} rdx_qkr_u128;

static int rdx_qkr_u128_mul10_add(rdx_qkr_u128 *x, unsigned digit) {
    /* x = x * 10 + digit with overflow detection. */
    uint64_t lo = x->lo, hi = x->hi;
    uint64_t lo_lo = (lo & 0xffffffffu) * 10u;
    uint64_t lo_hi = (lo >> 32) * 10u + (lo_lo >> 32);
    uint64_t new_lo = (lo_lo & 0xffffffffu) | (lo_hi << 32);
    uint64_t carry = lo_hi >> 32;
    uint64_t new_hi;
    if (hi > (UINT64_MAX - carry) / 10u) return 0;
    new_hi = hi * 10u + carry;
    if (new_lo > UINT64_MAX - digit) {
        if (new_hi == UINT64_MAX) return 0;
        new_hi++;
        new_lo += digit; /* wraps */
    } else {
        new_lo += digit;
    }
    x->lo = new_lo;
    x->hi = new_hi;
    return 1;
}

static int rdx_qkr_u128_from_string(const char *s, rdx_qkr_u128 *out, int *negative) {
    rdx_qkr_u128 v = {0, 0};
    int neg = 0;
    if (!s || !*s) return 0;
    if (*s == '-') {
        neg = 1;
        s++;
    } else if (*s == '+') {
        s++;
    }
    if (!*s) return 0;
    for (; *s; s++) {
        if (*s < '0' || *s > '9') return 0;
        if (!rdx_qkr_u128_mul10_add(&v, (unsigned)(*s - '0'))) return 0;
    }
    *out = v;
    *negative = neg;
    return 1;
}

static void rdx_qkr_u128_negate(rdx_qkr_u128 *x) {
    x->lo = ~x->lo;
    x->hi = ~x->hi;
    x->lo++;
    if (x->lo == 0) x->hi++;
}

static unsigned rdx_qkr_u128_divmod10(rdx_qkr_u128 *x) {
    /* In-place x /= 10, returns remainder. */
    uint64_t rem = 0;
    uint64_t parts[4] = {x->hi >> 32, x->hi & 0xffffffffu, x->lo >> 32, x->lo & 0xffffffffu};
    int i;
    for (i = 0; i < 4; i++) {
        uint64_t cur = (rem << 32) | parts[i];
        parts[i] = cur / 10u;
        rem = cur % 10u;
    }
    x->hi = (parts[0] << 32) | parts[1];
    x->lo = (parts[2] << 32) | parts[3];
    return (unsigned)rem;
}

static void rdx_qkr_u128_to_string(rdx_qkr_u128 x, int negative, char *buf, size_t buf_size) {
    char tmp[48];
    size_t n = 0, i = 0;
    if (x.lo == 0 && x.hi == 0) {
        tmp[n++] = '0';
    } else {
        while (x.lo != 0 || x.hi != 0) {
            tmp[n++] = (char)('0' + rdx_qkr_u128_divmod10(&x));
        }
    }
    if (negative) tmp[n++] = '-';
    if (n + 1 > buf_size) n = buf_size - 1;
    while (n) buf[i++] = tmp[--n];
    buf[i] = '\0';
}

static void rdx_qkr_store_i128(uint8_t *dst, rdx_qkr_u128 v, int negative) {
    /* little-endian two's-complement 128-bit, DuckDB hugeint layout. */
    if (negative) rdx_qkr_u128_negate(&v);
    memcpy(dst, &v.lo, 8);
    memcpy(dst + 8, &v.hi, 8);
}

static void rdx_qkr_load_i128(const uint8_t *src, rdx_qkr_u128 *v, int *negative, int is_signed) {
    memcpy(&v->lo, src, 8);
    memcpy(&v->hi, src + 8, 8);
    *negative = 0;
    if (is_signed && (v->hi & 0x8000000000000000ull)) {
        *negative = 1;
        rdx_qkr_u128_negate(v);
    }
}

/* ---------------- UUID <-> hugeint bytes ---------------- */

static int rdx_qkr_hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int rdx_qkr_uuid_to_bytes(const char *s, uint8_t out[16]) {
    /* Canonical hex (with or without dashes) -> DuckDB hugeint physical:
     * big-endian hex -> hi/lo with the sign bit flipped for order. */
    uint8_t be[16];
    size_t nd = 0;
    uint64_t hi, lo;
    int high = -1;
    for (; *s; s++) {
        int nib;
        if (*s == '-') continue;
        nib = rdx_qkr_hex_nibble(*s);
        if (nib < 0 || nd >= 32) return 0;
        if (high < 0) {
            high = nib;
        } else {
            be[nd / 2] = (uint8_t)((high << 4) | nib);
            high = -1;
            nd += 2;
        }
    }
    if (nd != 32 || high >= 0) return 0;
    hi = 0;
    lo = 0;
    {
        int i;
        for (i = 0; i < 8; i++) hi = (hi << 8) | be[i];
        for (i = 8; i < 16; i++) lo = (lo << 8) | be[i];
    }
    hi ^= 0x8000000000000000ull;
    memcpy(out, &lo, 8);
    memcpy(out + 8, &hi, 8);
    return 1;
}

static void rdx_qkr_uuid_from_bytes(const uint8_t *src, char out[37]) {
    static const char hexdig[] = "0123456789abcdef";
    uint64_t lo, hi;
    uint8_t be[16];
    int i, pos = 0;
    memcpy(&lo, src, 8);
    memcpy(&hi, src + 8, 8);
    hi ^= 0x8000000000000000ull;
    for (i = 0; i < 8; i++) be[i] = (uint8_t)(hi >> (8 * (7 - i)));
    for (i = 0; i < 8; i++) be[8 + i] = (uint8_t)(lo >> (8 * (7 - i)));
    for (i = 0; i < 16; i++) {
        if (i == 4 || i == 6 || i == 8 || i == 10) out[pos++] = '-';
        out[pos++] = hexdig[be[i] >> 4];
        out[pos++] = hexdig[be[i] & 0xf];
    }
    out[pos] = '\0';
}

/* ---------------- spec <-> rdx_qk_type ---------------- */

/* Building a type from a spec recurses into children and can Rf_error()
 * (nesting limit, OOM) after the parent type is allocated. The body runs under
 * R_UnwindProtect so the in-flight type is freed on any unwind; recursive child
 * builds nest their own protection, so each level frees exactly its own type. */
static rdx_qk_type *rdx_qkr_type_from_spec(SEXP spec, unsigned depth);

typedef struct {
    SEXP spec;
    unsigned depth;
    rdx_qk_type *t;
} rdx_qkr_tfs_ctx;

static void rdx_qkr_tfs_cleanup(void *vctx, Rboolean jump) {
    rdx_qkr_tfs_ctx *c = (rdx_qkr_tfs_ctx *)vctx;
    if (jump && c->t) { rdx_qk_type_free(c->t); c->t = NULL; }
}

static SEXP rdx_qkr_tfs_body(void *vctx) {
    rdx_qkr_tfs_ctx *ctx = (rdx_qkr_tfs_ctx *)vctx;
    SEXP spec = ctx->spec;
    unsigned depth = ctx->depth;
    rdx_qk_type *t;
    SEXP children, labels;
    R_xlen_t i;
    if (depth > RDX_QK_MAX_NESTING) Rf_error("Rducks quack codec: type spec exceeds nesting limit");
    if (TYPEOF(spec) != VECSXP) Rf_error("Rducks quack codec: type spec must be a list");
    t = rdx_qk_type_new((uint32_t)rdx_qkr_int_field(spec, "id", 0));
    if (!t) Rf_error("Rducks quack codec: out of memory building type");
    ctx->t = t; /* register for cleanup before any further error can fire */
    t->width = (uint8_t)rdx_qkr_int_field(spec, "width", 0);
    t->scale = (uint8_t)rdx_qkr_int_field(spec, "scale", 0);
    t->array_size = (uint32_t)rdx_qkr_int_field(spec, "array_size", 0);
    children = rdx_qkr_list_elt(spec, "children");
    if (children != R_NilValue) {
        SEXP names = Rf_getAttrib(children, R_NamesSymbol);
        for (i = 0; i < Rf_xlength(children); i++) {
            const char *name = (names != R_NilValue && STRING_ELT(names, i) != NA_STRING)
                                   ? CHAR(STRING_ELT(names, i))
                                   : "";
            rdx_qk_type *child = rdx_qkr_type_from_spec(VECTOR_ELT(children, i), depth + 1);
            if (!rdx_qk_type_add_child(t, child, name)) {
                rdx_qk_type_free(child); /* orphan: not attached to t */
                Rf_error("Rducks quack codec: out of memory building type children");
            }
        }
    }
    labels = rdx_qkr_list_elt(spec, "enum_labels");
    if (labels != R_NilValue && Rf_xlength(labels) > 0) {
        R_xlen_t n = Rf_xlength(labels);
        const char **tmp = (const char **)R_alloc((size_t)n, sizeof(char *));
        for (i = 0; i < n; i++) tmp[i] = CHAR(STRING_ELT(labels, i));
        if (!rdx_qk_type_set_enum_labels(t, tmp, (uint32_t)n)) {
            Rf_error("Rducks quack codec: out of memory building enum labels");
        }
    }
    return R_NilValue;
}

static rdx_qk_type *rdx_qkr_type_from_spec(SEXP spec, unsigned depth) {
    rdx_qkr_tfs_ctx ctx;
    SEXP cont;
    ctx.spec = spec;
    ctx.depth = depth;
    ctx.t = NULL;
    cont = PROTECT(R_MakeUnwindCont());
    R_UnwindProtect(rdx_qkr_tfs_body, &ctx, rdx_qkr_tfs_cleanup, &ctx, cont);
    UNPROTECT(1);
    return ctx.t;
}

static SEXP rdx_qkr_spec_from_type(const rdx_qk_type *t) {
    SEXP spec = PROTECT(Rf_allocVector(VECSXP, 6));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 6));
    SEXP children, child_names, labels;
    uint32_t i;
    SET_STRING_ELT(names, 0, Rf_mkChar("id"));
    SET_STRING_ELT(names, 1, Rf_mkChar("width"));
    SET_STRING_ELT(names, 2, Rf_mkChar("scale"));
    SET_STRING_ELT(names, 3, Rf_mkChar("array_size"));
    SET_STRING_ELT(names, 4, Rf_mkChar("children"));
    SET_STRING_ELT(names, 5, Rf_mkChar("enum_labels"));
    Rf_setAttrib(spec, R_NamesSymbol, names);
    SET_VECTOR_ELT(spec, 0, Rf_ScalarInteger((int)t->id));
    SET_VECTOR_ELT(spec, 1, Rf_ScalarInteger((int)t->width));
    SET_VECTOR_ELT(spec, 2, Rf_ScalarInteger((int)t->scale));
    SET_VECTOR_ELT(spec, 3, Rf_ScalarInteger((int)t->array_size));
    children = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)t->nchildren));
    child_names = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)t->nchildren));
    for (i = 0; i < t->nchildren; i++) {
        SET_VECTOR_ELT(children, (R_xlen_t)i, rdx_qkr_spec_from_type(t->children[i]));
        SET_STRING_ELT(child_names, (R_xlen_t)i,
                       Rf_mkChar(t->names && t->names[i] ? t->names[i] : ""));
    }
    Rf_setAttrib(children, R_NamesSymbol, child_names);
    SET_VECTOR_ELT(spec, 4, children);
    labels = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)t->enum_count));
    for (i = 0; i < t->enum_count; i++) {
        SET_STRING_ELT(labels, (R_xlen_t)i,
                       Rf_mkChar(t->enum_labels && t->enum_labels[i] ? t->enum_labels[i] : ""));
    }
    SET_VECTOR_ELT(spec, 5, labels);
    UNPROTECT(5);
    return spec;
}

/* ---------------- column storage -> rdx_qk_vector ---------------- */

static void rdx_qkr_expect_length(SEXP x, uint64_t rows, const char *what) {
    if ((uint64_t)Rf_xlength(x) != rows) {
        Rf_error("Rducks quack codec: %s storage has %lld values but the chunk has %llu rows",
                 what, (long long)Rf_xlength(x), (unsigned long long)rows);
    }
}

static int rdx_qkr_is_signed_int(uint32_t id) {
    return id == RDX_QK_LTYPE_TINYINT || id == RDX_QK_LTYPE_SMALLINT || id == RDX_QK_LTYPE_INTEGER;
}

static rdx_qk_vector *rdx_qkr_vector_from_column(const rdx_qk_type *t, SEXP column,
                                                 uint64_t rows, unsigned depth);

static void rdx_qkr_apply_valid(rdx_qk_vector *v, SEXP valid, uint64_t rows) {
    uint64_t i;
    if (valid == R_NilValue) return;
    if (TYPEOF(valid) != LGLSXP) Rf_error("Rducks quack codec: column valid mask must be logical");
    rdx_qkr_expect_length(valid, rows, "validity");
    for (i = 0; i < rows; i++) {
        int ok = LOGICAL(valid)[i];
        if (ok == NA_LOGICAL || !ok) {
            if (!v->has_validity && !rdx_qk_vector_alloc_validity(v)) {
                Rf_error("Rducks quack codec: out of memory allocating validity");
            }
            rdx_qk_vector_set_null(v, i);
        }
    }
}

static void rdx_qkr_fill_fixed_from_int(rdx_qk_vector *v, SEXP data, uint64_t rows,
                                        size_t width, int is_signed) {
    uint64_t i;
    if (TYPEOF(data) != INTSXP) Rf_error("Rducks quack codec: expected integer storage");
    rdx_qkr_expect_length(data, rows, "integer");
    for (i = 0; i < rows; i++) {
        int value = INTEGER(data)[i];
        long long sv;
        if (value == NA_INTEGER) {
            rdx_qk_vector_set_null(v, i);
            value = 0;
        }
        sv = value;
        if (!is_signed && sv < 0) Rf_error("Rducks quack codec: negative value in unsigned storage");
        switch (width) {
        case 1: {
            if (is_signed ? (sv < -128 || sv > 127) : (sv > 255)) {
                Rf_error("Rducks quack codec: value out of range for 1-byte storage");
            }
            v->data[i] = (uint8_t)(sv & 0xff);
            break;
        }
        case 2: {
            uint16_t u;
            if (is_signed ? (sv < -32768 || sv > 32767) : (sv > 65535)) {
                Rf_error("Rducks quack codec: value out of range for 2-byte storage");
            }
            u = (uint16_t)(sv & 0xffff);
            memcpy(v->data + 2 * i, &u, 2);
            break;
        }
        case 4: {
            uint32_t u = (uint32_t)(sv & 0xffffffffu);
            memcpy(v->data + 4 * i, &u, 4);
            break;
        }
        default:
            Rf_error("Rducks quack codec: unexpected integer storage width");
        }
    }
}

static void rdx_qkr_fill_i64_family(rdx_qk_vector *v, const rdx_qk_type *t, SEXP data,
                                    uint64_t rows) {
    /* BIGINT/UBIGINT/HUGEINT/UHUGEINT/DECIMAL via decimal strings. */
    size_t width = rdx_qk_type_fixed_width(t);
    int is_signed = (t->id == RDX_QK_LTYPE_BIGINT || t->id == RDX_QK_LTYPE_HUGEINT ||
                     t->id == RDX_QK_LTYPE_DECIMAL);
    uint64_t i;
    if (TYPEOF(data) != STRSXP) Rf_error("Rducks quack codec: expected character storage");
    rdx_qkr_expect_length(data, rows, "integer-string");
    for (i = 0; i < rows; i++) {
        SEXP elt = STRING_ELT(data, i);
        rdx_qkr_u128 val;
        int negative;
        if (elt == NA_STRING) {
            rdx_qk_vector_set_null(v, i);
            val.lo = 0;
            val.hi = 0;
            negative = 0;
        } else if (!rdx_qkr_u128_from_string(CHAR(elt), &val, &negative)) {
            Rf_error("Rducks quack codec: invalid integer string '%s'", CHAR(elt));
        }
        if (negative && !is_signed) {
            Rf_error("Rducks quack codec: negative value in unsigned storage");
        }
        if (width == 16) {
            if (is_signed) {
                /* range: |v| <= 2^127 (with -2^127 allowed) */
                if (val.hi > 0x8000000000000000ull ||
                    (val.hi == 0x8000000000000000ull && (val.lo != 0 || !negative))) {
                    Rf_error("Rducks quack codec: value out of range for hugeint storage");
                }
            }
            rdx_qkr_store_i128(v->data + 16 * i, val, negative);
        } else if (width == 8) {
            uint64_t u;
            if (val.hi != 0) Rf_error("Rducks quack codec: value out of range for 8-byte storage");
            if (is_signed) {
                if (negative ? (val.lo > 0x8000000000000000ull) : (val.lo > 0x7fffffffffffffffull)) {
                    Rf_error("Rducks quack codec: value out of range for bigint storage");
                }
                u = negative ? (~val.lo + 1u) : val.lo;
            } else {
                u = val.lo;
            }
            memcpy(v->data + 8 * i, &u, 8);
        } else {
            /* small decimals: width <= 9 -> 2/4 bytes */
            int64_t sv;
            if (val.hi != 0 || val.lo > 0x7fffffffffffffffull) {
                Rf_error("Rducks quack codec: value out of range for decimal storage");
            }
            sv = negative ? -(int64_t)val.lo : (int64_t)val.lo;
            if (width == 2) {
                int16_t s16;
                if (sv < -32768 || sv > 32767) {
                    Rf_error("Rducks quack codec: value out of range for decimal storage");
                }
                s16 = (int16_t)sv;
                memcpy(v->data + 2 * i, &s16, 2);
            } else if (width == 4) {
                int32_t s32;
                if (sv < INT32_MIN || sv > INT32_MAX) {
                    Rf_error("Rducks quack codec: value out of range for decimal storage");
                }
                s32 = (int32_t)sv;
                memcpy(v->data + 4 * i, &s32, 4);
            } else {
                Rf_error("Rducks quack codec: unexpected decimal storage width");
            }
        }
    }
}

static void rdx_qkr_fill_double_family(rdx_qk_vector *v, const rdx_qk_type *t, SEXP data,
                                       uint64_t rows) {
    uint64_t i;
    if (TYPEOF(data) != REALSXP) Rf_error("Rducks quack codec: expected double storage");
    rdx_qkr_expect_length(data, rows, "double");
    for (i = 0; i < rows; i++) {
        double x = REAL(data)[i];
        if (ISNAN(x) && ISNA(REAL(data)[i])) {
            rdx_qk_vector_set_null(v, i);
            x = 0;
        }
        switch (t->id) {
        case RDX_QK_LTYPE_DOUBLE:
            memcpy(v->data + 8 * i, &x, 8);
            break;
        case RDX_QK_LTYPE_FLOAT: {
            float f = (float)x;
            memcpy(v->data + 4 * i, &f, 4);
            break;
        }
        case RDX_QK_LTYPE_UINTEGER: {
            uint32_t u;
            if (x < 0 || x > 4294967295.0) {
                Rf_error("Rducks quack codec: value out of range for uinteger storage");
            }
            u = (uint32_t)x;
            memcpy(v->data + 4 * i, &u, 4);
            break;
        }
        default: { /* microsecond family */
            int64_t us;
            if (x > 9007199254740992.0 || x < -9007199254740992.0) {
                Rf_error("Rducks quack codec: temporal value exceeds the exact double range");
            }
            us = (int64_t)x;
            memcpy(v->data + 8 * i, &us, 8);
            break;
        }
        }
    }
}

/* Constructing a vector from an R column can Rf_error() (longjmp) deep in a fill
 * helper or a recursive child build, after `v` and its buffers are allocated.
 * The body runs under R_UnwindProtect so the in-flight vector is freed on any
 * unwind; the self-free-before-error sites were removed in favour of this single
 * cleanup path. Recursive child builds nest their own protection, so each level
 * frees exactly its own vector. */
typedef struct {
    const rdx_qk_type *t;
    SEXP column;
    uint64_t rows;
    unsigned depth;
    rdx_qk_vector *v;
} rdx_qkr_vfc_ctx;

static void rdx_qkr_vfc_cleanup(void *vctx, Rboolean jump) {
    rdx_qkr_vfc_ctx *c = (rdx_qkr_vfc_ctx *)vctx;
    if (jump && c->v) { rdx_qk_vector_free(c->v); c->v = NULL; }
}

static SEXP rdx_qkr_vfc_body(void *vctx) {
    rdx_qkr_vfc_ctx *ctx = (rdx_qkr_vfc_ctx *)vctx;
    const rdx_qk_type *t = ctx->t;
    SEXP column = ctx->column;
    uint64_t rows = ctx->rows;
    unsigned depth = ctx->depth;
    rdx_qk_vector *v;
    SEXP valid, data;
    uint64_t i;
    if (depth > RDX_QK_MAX_NESTING) Rf_error("Rducks quack codec: column exceeds nesting limit");
    if (TYPEOF(column) != VECSXP) Rf_error("Rducks quack codec: column must be a list");
    valid = rdx_qkr_list_elt(column, "valid");
    data = rdx_qkr_list_elt(column, "data");
    if (data == R_NilValue) Rf_error("Rducks quack codec: column is missing its data");
    v = rdx_qk_vector_new(t, rows);
    if (!v) Rf_error("Rducks quack codec: out of memory building vector");
    ctx->v = v; /* register for cleanup before any further error can fire */

    switch (t->id) {
    case RDX_QK_LTYPE_VARCHAR: {
        size_t pool = 0, fill = 0;
        if (TYPEOF(data) != STRSXP) {
            Rf_error("Rducks quack codec: expected character storage for VARCHAR");
        }
        rdx_qkr_expect_length(data, rows, "varchar");
        for (i = 0; i < rows; i++) {
            SEXP elt = STRING_ELT(data, i);
            if (elt != NA_STRING) pool += strlen(Rf_translateCharUTF8(elt));
        }
        if (!rdx_qk_vector_alloc_strings(v, pool)) {
            Rf_error("Rducks quack codec: out of memory building string vector");
        }
        for (i = 0; i < rows; i++) {
            SEXP elt = STRING_ELT(data, i);
            v->str_offsets[i] = fill;
            if (elt == NA_STRING) {
                rdx_qk_vector_set_null(v, i);
            } else {
                const char *s = Rf_translateCharUTF8(elt);
                size_t n = strlen(s);
                memcpy(v->str_pool + fill, s, n);
                fill += n;
            }
        }
        v->str_offsets[rows] = fill;
        v->str_pool_size = fill;
        break;
    }
    case RDX_QK_LTYPE_BIT: {
        size_t pool = 0, fill = 0;
        if (TYPEOF(data) != VECSXP) {
            Rf_error("Rducks quack codec: expected list-of-rducks_bits storage for BIT");
        }
        rdx_qkr_expect_length(data, rows, "bit");
        for (i = 0; i < rows; i++) {
            SEXP elt = VECTOR_ELT(data, i);
            if (elt != R_NilValue) {
                int bit_length;
                if (TYPEOF(elt) != VECSXP || XLENGTH(elt) < 2) {
                    Rf_error("Rducks quack codec: BIT rows must be rducks_bits objects or NULL");
                }
                bit_length = Rf_asInteger(VECTOR_ELT(elt, 1));
                if (bit_length <= 0) {
                    Rf_error("Rducks quack codec: rducks_bits object has invalid length");
                }
                pool += rdx_qkr_bit_physical_len(bit_length);
            }
        }
        if (!rdx_qk_vector_alloc_strings(v, pool)) {
            Rf_error("Rducks quack codec: out of memory building bit vector");
        }
        for (i = 0; i < rows; i++) {
            SEXP elt = VECTOR_ELT(data, i);
            v->str_offsets[i] = fill;
            if (elt == R_NilValue) {
                rdx_qk_vector_set_null(v, i);
            } else {
                fill += rdx_qkr_bit_to_physical(elt, v->str_pool + fill);
            }
        }
        v->str_offsets[rows] = fill;
        v->str_pool_size = fill;
        break;
    }
    case RDX_QK_LTYPE_BLOB: {
        size_t pool = 0, fill = 0;
        if (TYPEOF(data) != VECSXP) {
            Rf_error("Rducks quack codec: expected list-of-raw storage for BLOB");
        }
        rdx_qkr_expect_length(data, rows, "blob");
        for (i = 0; i < rows; i++) {
            SEXP elt = VECTOR_ELT(data, i);
            if (elt != R_NilValue) {
                if (TYPEOF(elt) != RAWSXP) {
                    Rf_error("Rducks quack codec: BLOB rows must be raw vectors or NULL");
                }
                pool += (size_t)Rf_xlength(elt);
            }
        }
        if (!rdx_qk_vector_alloc_strings(v, pool)) {
            Rf_error("Rducks quack codec: out of memory building blob vector");
        }
        for (i = 0; i < rows; i++) {
            SEXP elt = VECTOR_ELT(data, i);
            v->str_offsets[i] = fill;
            if (elt == R_NilValue) {
                rdx_qk_vector_set_null(v, i);
            } else {
                size_t n = (size_t)Rf_xlength(elt);
                memcpy(v->str_pool + fill, RAW(elt), n);
                fill += n;
            }
        }
        v->str_offsets[rows] = fill;
        v->str_pool_size = fill;
        break;
    }
    case RDX_QK_LTYPE_STRUCT:
    case RDX_QK_LTYPE_UNION: {
        if ((uint64_t)Rf_xlength(data) != t->nchildren) {
            Rf_error("Rducks quack codec: struct column member count disagrees with its type");
        }
        v->children = (rdx_qk_vector **)calloc(t->nchildren ? t->nchildren : 1, sizeof(*v->children));
        if (!v->children) {
            Rf_error("Rducks quack codec: out of memory building struct children");
        }
        for (i = 0; i < t->nchildren; i++) {
            v->children[i] = rdx_qkr_vector_from_column(t->children[i],
                                                        VECTOR_ELT(data, (R_xlen_t)i), rows, depth + 1);
            v->nchildren = (uint32_t)(i + 1);
        }
        break;
    }
    case RDX_QK_LTYPE_LIST:
    case RDX_QK_LTYPE_MAP: {
        SEXP offsets = rdx_qkr_list_elt(data, "offsets");
        SEXP lengths = rdx_qkr_list_elt(data, "lengths");
        SEXP child = rdx_qkr_list_elt(data, "child");
        uint64_t child_rows = 0;
        if (TYPEOF(offsets) != REALSXP || TYPEOF(lengths) != REALSXP || child == R_NilValue) {
            Rf_error("Rducks quack codec: LIST storage requires offsets, lengths and child");
        }
        rdx_qkr_expect_length(offsets, rows, "list offsets");
        rdx_qkr_expect_length(lengths, rows, "list lengths");
        for (i = 0; i < rows; i++) {
            double end = REAL(offsets)[i] + REAL(lengths)[i];
            if (end > (double)child_rows) child_rows = (uint64_t)end;
        }
        {
            SEXP cd = rdx_qkr_list_elt(child, "data");
            (void)cd;
        }
        if (!rdx_qk_vector_alloc_list(v, 0)) {
            Rf_error("Rducks quack codec: out of memory building list vector");
        }
        for (i = 0; i < rows; i++) {
            double off = REAL(offsets)[i], len = REAL(lengths)[i];
            if (off < 0 || len < 0 || off + len > 9007199254740992.0) {
                Rf_error("Rducks quack codec: invalid list entry bounds");
            }
            v->list_offsets[i] = (uint64_t)off;
            v->list_lengths[i] = (uint64_t)len;
        }
        v->children = (rdx_qk_vector **)calloc(1, sizeof(*v->children));
        if (!v->children) {
            Rf_error("Rducks quack codec: out of memory building list child");
        }
        {
            /* child rows comes from the child column's own storage length */
            SEXP child_valid = rdx_qkr_list_elt(child, "valid");
            SEXP child_data = rdx_qkr_list_elt(child, "data");
            uint64_t declared = 0;
            if (child_valid != R_NilValue) {
                declared = (uint64_t)Rf_xlength(child_valid);
            } else if (TYPEOF(child_data) == VECSXP &&
                       (t->children[0]->id == RDX_QK_LTYPE_LIST ||
                        t->children[0]->id == RDX_QK_LTYPE_MAP ||
                        t->children[0]->id == RDX_QK_LTYPE_STRUCT ||
                        t->children[0]->id == RDX_QK_LTYPE_UNION ||
                        t->children[0]->id == RDX_QK_LTYPE_ARRAY ||
                        t->children[0]->id == RDX_QK_LTYPE_INTERVAL)) {
                declared = child_rows; /* nested child: trust computed extent */
            } else if (child_data != R_NilValue) {
                declared = (uint64_t)Rf_xlength(child_data);
            }
            if (declared < child_rows) {
                Rf_error("Rducks quack codec: list entries reference rows beyond the child column");
            }
            v->list_child_rows = declared;
            v->children[0] = rdx_qkr_vector_from_column(t->children[0], child, declared, depth + 1);
            v->nchildren = 1;
        }
        break;
    }
    case RDX_QK_LTYPE_ARRAY: {
        SEXP child = rdx_qkr_list_elt(data, "child");
        uint64_t child_rows = rows * (uint64_t)t->array_size;
        if (child == R_NilValue || t->nchildren != 1) {
            Rf_error("Rducks quack codec: ARRAY storage requires a child column");
        }
        v->children = (rdx_qk_vector **)calloc(1, sizeof(*v->children));
        if (!v->children) {
            Rf_error("Rducks quack codec: out of memory building array child");
        }
        v->children[0] = rdx_qkr_vector_from_column(t->children[0], child, child_rows, depth + 1);
        v->nchildren = 1;
        break;
    }
    case RDX_QK_LTYPE_INTERVAL: {
        SEXP months = rdx_qkr_list_elt(data, "months");
        SEXP days = rdx_qkr_list_elt(data, "days");
        SEXP micros = rdx_qkr_list_elt(data, "micros");
        if (TYPEOF(months) != INTSXP || TYPEOF(days) != INTSXP || TYPEOF(micros) != REALSXP) {
            Rf_error("Rducks quack codec: INTERVAL storage requires months, days, micros");
        }
        rdx_qkr_expect_length(months, rows, "interval months");
        rdx_qkr_expect_length(days, rows, "interval days");
        rdx_qkr_expect_length(micros, rows, "interval micros");
        if (!rdx_qk_vector_alloc_fixed(v)) {
            Rf_error("Rducks quack codec: out of memory building interval vector");
        }
        for (i = 0; i < rows; i++) {
            int32_t m = INTEGER(months)[i], d = INTEGER(days)[i];
            double usd = REAL(micros)[i];
            int64_t us;
            if (m == NA_INTEGER || d == NA_INTEGER || ISNA(usd)) {
                rdx_qk_vector_set_null(v, i);
                m = 0;
                d = 0;
                usd = 0;
            }
            if (usd > 9007199254740992.0 || usd < -9007199254740992.0) {
                Rf_error("Rducks quack codec: interval micros exceed the exact double range");
            }
            us = (int64_t)usd;
            memcpy(v->data + 16 * i, &m, 4);
            memcpy(v->data + 16 * i + 4, &d, 4);
            memcpy(v->data + 16 * i + 8, &us, 8);
        }
        break;
    }
    case RDX_QK_LTYPE_UUID: {
        if (TYPEOF(data) != STRSXP) {
            Rf_error("Rducks quack codec: expected character storage for UUID");
        }
        rdx_qkr_expect_length(data, rows, "uuid");
        if (!rdx_qk_vector_alloc_fixed(v)) {
            Rf_error("Rducks quack codec: out of memory building uuid vector");
        }
        for (i = 0; i < rows; i++) {
            SEXP elt = STRING_ELT(data, i);
            if (elt == NA_STRING) {
                rdx_qk_vector_set_null(v, i);
                memset(v->data + 16 * i, 0, 16);
            } else if (!rdx_qkr_uuid_to_bytes(CHAR(elt), v->data + 16 * i)) {
                Rf_error("Rducks quack codec: invalid UUID string");
            }
        }
        break;
    }
    case RDX_QK_LTYPE_ENUM: {
        size_t width = rdx_qk_type_fixed_width(t);
        if (TYPEOF(data) != INTSXP) {
            Rf_error("Rducks quack codec: expected integer codes for ENUM");
        }
        rdx_qkr_expect_length(data, rows, "enum");
        if (!rdx_qk_vector_alloc_fixed(v)) {
            Rf_error("Rducks quack codec: out of memory building enum vector");
        }
        for (i = 0; i < rows; i++) {
            int code = INTEGER(data)[i];
            uint32_t physical;
            if (code == NA_INTEGER) {
                rdx_qk_vector_set_null(v, i);
                physical = 0;
            } else if (code < 1 || (uint32_t)code > t->enum_count) {
                Rf_error("Rducks quack codec: enum code out of range");
            } else {
                physical = (uint32_t)(code - 1);
            }
            if (width == 1) {
                v->data[i] = (uint8_t)physical;
            } else if (width == 2) {
                uint16_t u = (uint16_t)physical;
                memcpy(v->data + 2 * i, &u, 2);
            } else {
                memcpy(v->data + 4 * i, &physical, 4);
            }
        }
        break;
    }
    case RDX_QK_LTYPE_BOOLEAN: {
        if (TYPEOF(data) != LGLSXP) {
            Rf_error("Rducks quack codec: expected logical storage for BOOLEAN");
        }
        rdx_qkr_expect_length(data, rows, "boolean");
        if (!rdx_qk_vector_alloc_fixed(v)) {
            Rf_error("Rducks quack codec: out of memory building boolean vector");
        }
        for (i = 0; i < rows; i++) {
            int x = LOGICAL(data)[i];
            if (x == NA_LOGICAL) {
                rdx_qk_vector_set_null(v, i);
                x = 0;
            }
            v->data[i] = x ? 1 : 0;
        }
        break;
    }
    case RDX_QK_LTYPE_TINYINT:
    case RDX_QK_LTYPE_SMALLINT:
    case RDX_QK_LTYPE_INTEGER:
    case RDX_QK_LTYPE_UTINYINT:
    case RDX_QK_LTYPE_USMALLINT:
    case RDX_QK_LTYPE_DATE:
        if (!rdx_qk_vector_alloc_fixed(v)) {
            Rf_error("Rducks quack codec: out of memory building integer vector");
        }
        rdx_qkr_fill_fixed_from_int(v, data, rows, rdx_qk_type_fixed_width(t),
                                    rdx_qkr_is_signed_int(t->id) || t->id == RDX_QK_LTYPE_DATE);
        break;
    case RDX_QK_LTYPE_BIGINT:
    case RDX_QK_LTYPE_UBIGINT:
    case RDX_QK_LTYPE_HUGEINT:
    case RDX_QK_LTYPE_UHUGEINT:
    case RDX_QK_LTYPE_DECIMAL:
        if (!rdx_qk_vector_alloc_fixed(v)) {
            Rf_error("Rducks quack codec: out of memory building integer vector");
        }
        rdx_qkr_fill_i64_family(v, t, data, rows);
        break;
    case RDX_QK_LTYPE_FLOAT:
    case RDX_QK_LTYPE_DOUBLE:
    case RDX_QK_LTYPE_UINTEGER:
    case RDX_QK_LTYPE_TIME:
    case RDX_QK_LTYPE_TIME_TZ:
    case RDX_QK_LTYPE_TIMESTAMP:
    case RDX_QK_LTYPE_TIMESTAMP_SEC:
    case RDX_QK_LTYPE_TIMESTAMP_MS:
    case RDX_QK_LTYPE_TIMESTAMP_NS:
    case RDX_QK_LTYPE_TIMESTAMP_TZ:
        if (!rdx_qk_vector_alloc_fixed(v)) {
            Rf_error("Rducks quack codec: out of memory building double-backed vector");
        }
        rdx_qkr_fill_double_family(v, t, data, rows);
        break;
    default:
        Rf_error("Rducks quack codec: logical type id %u is not on the Rducks wire yet",
                 (unsigned)t->id);
    }
    rdx_qkr_apply_valid(v, valid, rows);
    return R_NilValue;
}

static rdx_qk_vector *rdx_qkr_vector_from_column(const rdx_qk_type *t, SEXP column,
                                                 uint64_t rows, unsigned depth) {
    rdx_qkr_vfc_ctx ctx;
    SEXP cont;
    ctx.t = t;
    ctx.column = column;
    ctx.rows = rows;
    ctx.depth = depth;
    ctx.v = NULL;
    cont = PROTECT(R_MakeUnwindCont());
    R_UnwindProtect(rdx_qkr_vfc_body, &ctx, rdx_qkr_vfc_cleanup, &ctx, cont);
    UNPROTECT(1);
    return ctx.v;
}

/* ---------------- rdx_qk_vector -> column storage ---------------- */

static SEXP rdx_qkr_named_list(int n, const char **names) {
    SEXP out = PROTECT(Rf_allocVector(VECSXP, n));
    SEXP nm = PROTECT(Rf_allocVector(STRSXP, n));
    int i;
    for (i = 0; i < n; i++) SET_STRING_ELT(nm, i, Rf_mkChar(names[i]));
    Rf_setAttrib(out, R_NamesSymbol, nm);
    UNPROTECT(2); /* out, nm: callers re-protect immediately, no allocation between */
    return out;
}

static SEXP rdx_qkr_column_from_vector(const rdx_qk_vector *v, unsigned depth);

static SEXP rdx_qkr_valid_from_vector(const rdx_qk_vector *v) {
    SEXP valid;
    uint64_t i;
    if (!v->has_validity) return R_NilValue;
    valid = PROTECT(Rf_allocVector(LGLSXP, (R_xlen_t)v->rows));
    for (i = 0; i < v->rows; i++) {
        LOGICAL(valid)[i] = rdx_qk_vector_row_is_valid(v, i) ? TRUE : FALSE;
    }
    UNPROTECT(1);
    return valid;
}

static SEXP rdx_qkr_data_from_vector(const rdx_qk_vector *v, unsigned depth) {
    const rdx_qk_type *t = v->type;
    uint64_t rows = v->rows, i;
    SEXP data;
    if (depth > RDX_QK_MAX_NESTING) Rf_error("Rducks quack codec: decoded column exceeds nesting limit");
    switch (t->id) {
    case RDX_QK_LTYPE_VARCHAR: {
        data = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)rows));
        for (i = 0; i < rows; i++) {
            if (!rdx_qk_vector_row_is_valid(v, i)) {
                SET_STRING_ELT(data, (R_xlen_t)i, NA_STRING);
            } else {
                uint64_t a = v->str_offsets[i], b = v->str_offsets[i + 1];
                SET_STRING_ELT(data, (R_xlen_t)i,
                               Rf_mkCharLenCE((const char *)(v->str_pool + a), (int)(b - a), CE_UTF8));
            }
        }
        break;
    }
    case RDX_QK_LTYPE_BIT: {
        data = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)rows));
        for (i = 0; i < rows; i++) {
            if (!rdx_qk_vector_row_is_valid(v, i)) {
                SET_VECTOR_ELT(data, (R_xlen_t)i, R_NilValue);
            } else {
                uint64_t a = v->str_offsets[i], b = v->str_offsets[i + 1];
                SEXP bits = rdx_qkr_bit_from_physical(v->str_pool + a, (size_t)(b - a));
                SET_VECTOR_ELT(data, (R_xlen_t)i, bits);
            }
        }
        break;
    }
    case RDX_QK_LTYPE_BLOB: {
        data = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)rows));
        for (i = 0; i < rows; i++) {
            if (!rdx_qk_vector_row_is_valid(v, i)) {
                SET_VECTOR_ELT(data, (R_xlen_t)i, R_NilValue);
            } else {
                uint64_t a = v->str_offsets[i], b = v->str_offsets[i + 1];
                SEXP raw = Rf_allocVector(RAWSXP, (R_xlen_t)(b - a));
                memcpy(RAW(raw), v->str_pool + a, (size_t)(b - a));
                SET_VECTOR_ELT(data, (R_xlen_t)i, raw);
            }
        }
        break;
    }
    case RDX_QK_LTYPE_STRUCT:
    case RDX_QK_LTYPE_UNION: {
        data = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)v->nchildren));
        {
            SEXP nm = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)v->nchildren));
            uint32_t k;
            for (k = 0; k < v->nchildren; k++) {
                SET_STRING_ELT(nm, (R_xlen_t)k,
                               Rf_mkChar(t->names && t->names[k] ? t->names[k] : ""));
                SET_VECTOR_ELT(data, (R_xlen_t)k, rdx_qkr_column_from_vector(v->children[k], depth + 1));
            }
            Rf_setAttrib(data, R_NamesSymbol, nm);
            UNPROTECT(1);
        }
        break;
    }
    case RDX_QK_LTYPE_LIST:
    case RDX_QK_LTYPE_MAP: {
        static const char *fields[] = {"offsets", "lengths", "child"};
        SEXP offsets, lengths;
        data = PROTECT(rdx_qkr_named_list(3, fields));
        offsets = Rf_allocVector(REALSXP, (R_xlen_t)rows);
        SET_VECTOR_ELT(data, 0, offsets);
        lengths = Rf_allocVector(REALSXP, (R_xlen_t)rows);
        SET_VECTOR_ELT(data, 1, lengths);
        for (i = 0; i < rows; i++) {
            REAL(offsets)[i] = (double)v->list_offsets[i];
            REAL(lengths)[i] = (double)v->list_lengths[i];
        }
        SET_VECTOR_ELT(data, 2, rdx_qkr_column_from_vector(v->children[0], depth + 1));
        break;
    }
    case RDX_QK_LTYPE_ARRAY: {
        static const char *fields[] = {"child"};
        data = PROTECT(rdx_qkr_named_list(1, fields));
        SET_VECTOR_ELT(data, 0, rdx_qkr_column_from_vector(v->children[0], depth + 1));
        break;
    }
    case RDX_QK_LTYPE_INTERVAL: {
        static const char *fields[] = {"months", "days", "micros"};
        SEXP months, days, micros;
        data = PROTECT(rdx_qkr_named_list(3, fields));
        months = Rf_allocVector(INTSXP, (R_xlen_t)rows);
        SET_VECTOR_ELT(data, 0, months);
        days = Rf_allocVector(INTSXP, (R_xlen_t)rows);
        SET_VECTOR_ELT(data, 1, days);
        micros = Rf_allocVector(REALSXP, (R_xlen_t)rows);
        SET_VECTOR_ELT(data, 2, micros);
        for (i = 0; i < rows; i++) {
            int32_t m, d;
            int64_t us;
            memcpy(&m, v->data + 16 * i, 4);
            memcpy(&d, v->data + 16 * i + 4, 4);
            memcpy(&us, v->data + 16 * i + 8, 8);
            if (!rdx_qk_vector_row_is_valid(v, i)) {
                INTEGER(months)[i] = NA_INTEGER;
                INTEGER(days)[i] = NA_INTEGER;
                REAL(micros)[i] = NA_REAL;
            } else {
                INTEGER(months)[i] = m;
                INTEGER(days)[i] = d;
                REAL(micros)[i] = (double)us;
            }
        }
        break;
    }
    case RDX_QK_LTYPE_UUID: {
        data = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)rows));
        for (i = 0; i < rows; i++) {
            if (!rdx_qk_vector_row_is_valid(v, i)) {
                SET_STRING_ELT(data, (R_xlen_t)i, NA_STRING);
            } else {
                char buf[37];
                rdx_qkr_uuid_from_bytes(v->data + 16 * i, buf);
                SET_STRING_ELT(data, (R_xlen_t)i, Rf_mkChar(buf));
            }
        }
        break;
    }
    case RDX_QK_LTYPE_ENUM: {
        size_t width = rdx_qk_type_fixed_width(t);
        data = PROTECT(Rf_allocVector(INTSXP, (R_xlen_t)rows));
        for (i = 0; i < rows; i++) {
            uint32_t physical = 0;
            if (!rdx_qk_vector_row_is_valid(v, i)) {
                INTEGER(data)[i] = NA_INTEGER;
                continue;
            }
            if (width == 1) {
                physical = v->data[i];
            } else if (width == 2) {
                uint16_t u;
                memcpy(&u, v->data + 2 * i, 2);
                physical = u;
            } else {
                memcpy(&physical, v->data + 4 * i, 4);
            }
            if (physical >= t->enum_count) Rf_error("Rducks quack codec: decoded enum code out of range");
            INTEGER(data)[i] = (int)(physical + 1);
        }
        break;
    }
    case RDX_QK_LTYPE_BOOLEAN: {
        data = PROTECT(Rf_allocVector(LGLSXP, (R_xlen_t)rows));
        for (i = 0; i < rows; i++) {
            LOGICAL(data)[i] = !rdx_qk_vector_row_is_valid(v, i) ? NA_LOGICAL
                                                                 : (v->data[i] ? TRUE : FALSE);
        }
        break;
    }
    case RDX_QK_LTYPE_TINYINT:
    case RDX_QK_LTYPE_SMALLINT:
    case RDX_QK_LTYPE_INTEGER:
    case RDX_QK_LTYPE_UTINYINT:
    case RDX_QK_LTYPE_USMALLINT:
    case RDX_QK_LTYPE_DATE: {
        size_t width = rdx_qk_type_fixed_width(t);
        int is_signed = rdx_qkr_is_signed_int(t->id) || t->id == RDX_QK_LTYPE_DATE;
        data = PROTECT(Rf_allocVector(INTSXP, (R_xlen_t)rows));
        for (i = 0; i < rows; i++) {
            if (!rdx_qk_vector_row_is_valid(v, i)) {
                INTEGER(data)[i] = NA_INTEGER;
                continue;
            }
            if (width == 1) {
                INTEGER(data)[i] = is_signed ? (int)(int8_t)v->data[i] : (int)v->data[i];
            } else if (width == 2) {
                if (is_signed) {
                    int16_t s;
                    memcpy(&s, v->data + 2 * i, 2);
                    INTEGER(data)[i] = s;
                } else {
                    uint16_t u;
                    memcpy(&u, v->data + 2 * i, 2);
                    INTEGER(data)[i] = u;
                }
            } else {
                int32_t s;
                memcpy(&s, v->data + 4 * i, 4);
                INTEGER(data)[i] = s;
            }
        }
        break;
    }
    case RDX_QK_LTYPE_BIGINT:
    case RDX_QK_LTYPE_UBIGINT:
    case RDX_QK_LTYPE_HUGEINT:
    case RDX_QK_LTYPE_UHUGEINT:
    case RDX_QK_LTYPE_DECIMAL: {
        size_t width = rdx_qk_type_fixed_width(t);
        int is_signed = (t->id == RDX_QK_LTYPE_BIGINT || t->id == RDX_QK_LTYPE_HUGEINT ||
                         t->id == RDX_QK_LTYPE_DECIMAL);
        data = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)rows));
        for (i = 0; i < rows; i++) {
            rdx_qkr_u128 val = {0, 0};
            int negative = 0;
            char buf[48];
            if (!rdx_qk_vector_row_is_valid(v, i)) {
                SET_STRING_ELT(data, (R_xlen_t)i, NA_STRING);
                continue;
            }
            if (width == 16) {
                rdx_qkr_load_i128(v->data + 16 * i, &val, &negative, is_signed);
            } else if (width == 8) {
                uint64_t u;
                memcpy(&u, v->data + 8 * i, 8);
                if (is_signed && (u & 0x8000000000000000ull)) {
                    negative = 1;
                    u = ~u + 1u;
                }
                val.lo = u;
            } else if (width == 4) {
                int32_t s;
                memcpy(&s, v->data + 4 * i, 4);
                if (s < 0) {
                    negative = 1;
                    val.lo = (uint64_t)(-(int64_t)s);
                } else {
                    val.lo = (uint64_t)s;
                }
            } else {
                int16_t s;
                memcpy(&s, v->data + 2 * i, 2);
                if (s < 0) {
                    negative = 1;
                    val.lo = (uint64_t)(-(int32_t)s);
                } else {
                    val.lo = (uint64_t)s;
                }
            }
            rdx_qkr_u128_to_string(val, negative, buf, sizeof(buf));
            SET_STRING_ELT(data, (R_xlen_t)i, Rf_mkChar(buf));
        }
        break;
    }
    case RDX_QK_LTYPE_FLOAT:
    case RDX_QK_LTYPE_DOUBLE:
    case RDX_QK_LTYPE_UINTEGER:
    case RDX_QK_LTYPE_TIME:
    case RDX_QK_LTYPE_TIME_TZ:
    case RDX_QK_LTYPE_TIMESTAMP:
    case RDX_QK_LTYPE_TIMESTAMP_SEC:
    case RDX_QK_LTYPE_TIMESTAMP_MS:
    case RDX_QK_LTYPE_TIMESTAMP_NS:
    case RDX_QK_LTYPE_TIMESTAMP_TZ: {
        data = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t)rows));
        for (i = 0; i < rows; i++) {
            if (!rdx_qk_vector_row_is_valid(v, i)) {
                REAL(data)[i] = NA_REAL;
                continue;
            }
            switch (t->id) {
            case RDX_QK_LTYPE_DOUBLE: {
                double x;
                memcpy(&x, v->data + 8 * i, 8);
                REAL(data)[i] = x;
                break;
            }
            case RDX_QK_LTYPE_FLOAT: {
                float f;
                memcpy(&f, v->data + 4 * i, 4);
                REAL(data)[i] = (double)f;
                break;
            }
            case RDX_QK_LTYPE_UINTEGER: {
                uint32_t u;
                memcpy(&u, v->data + 4 * i, 4);
                REAL(data)[i] = (double)u;
                break;
            }
            default: {
                int64_t us;
                memcpy(&us, v->data + 8 * i, 8);
                if (us > 9007199254740992ll || us < -9007199254740992ll) {
                    Rf_error("Rducks quack codec: decoded temporal value exceeds the exact double range");
                }
                REAL(data)[i] = (double)us;
                break;
            }
            }
        }
        break;
    }
    default:
        Rf_error("Rducks quack codec: logical type id %u is not on the Rducks wire yet",
                 (unsigned)t->id);
    }
    UNPROTECT(1); /* data; caller reprotects via SET_VECTOR_ELT */
    return data;
}

static SEXP rdx_qkr_column_from_vector(const rdx_qk_vector *v, unsigned depth) {
    static const char *fields[] = {"valid", "data", "rows"};
    SEXP column = PROTECT(rdx_qkr_named_list(3, fields));
    SET_VECTOR_ELT(column, 0, rdx_qkr_valid_from_vector(v));
    SET_VECTOR_ELT(column, 1, rdx_qkr_data_from_vector(v, depth));
    /* The decoded row count, used by the bridge to size nested children whose
     * extent cannot be derived from a flat data length (e.g. list-of-list). */
    SET_VECTOR_ELT(column, 2, Rf_ScalarReal((double)v->rows));
    UNPROTECT(1);
    return column;
}

/* ---------------- entry points ---------------- */

/* Building the chunk from R columns and encoding it can Rf_error() (longjmp)
 * deep in the helpers, so the chunk and the detached writer buffer are tracked
 * in a context and freed by an R_UnwindProtect cleanup that runs on both normal
 * return and unwinding. Worker processes are long-lived; an error path must not
 * leak the chunk. */
typedef struct {
    rdx_qk_chunk *chunk;   /* freed by cleanup */
    uint8_t *bytes;        /* detached writer buffer, freed by cleanup */
    uint64_t rows;
    SEXP types_spec;
    SEXP columns;
} rdx_qkr_encode_ctx;

static void rdx_qkr_encode_cleanup(void *data, Rboolean jump) {
    rdx_qkr_encode_ctx *ctx = (rdx_qkr_encode_ctx *)data;
    (void)jump;
    if (ctx->chunk) { rdx_qk_chunk_free(ctx->chunk); ctx->chunk = NULL; }
    if (ctx->bytes) { free(ctx->bytes); ctx->bytes = NULL; }
}

static SEXP rdx_qkr_encode_body(void *data) {
    rdx_qkr_encode_ctx *ctx = (rdx_qkr_encode_ctx *)data;
    rdx_qk_chunk *chunk = ctx->chunk;
    rdx_qk_writer w;
    rdx_qk_error err = {{0}};
    SEXP out;
    size_t nbytes;
    R_xlen_t i, ncolumns = Rf_xlength(ctx->columns);
    for (i = 0; i < ncolumns; i++) {
        chunk->types[i] = rdx_qkr_type_from_spec(VECTOR_ELT(ctx->types_spec, i), 0);
    }
    for (i = 0; i < ncolumns; i++) {
        chunk->columns[i] = rdx_qkr_vector_from_column(chunk->types[i], VECTOR_ELT(ctx->columns, i), ctx->rows, 0);
    }
    rdx_qk_writer_init(&w);
    if (!rdx_qk_chunk_encode(&w, chunk, &err)) {
        rdx_qk_writer_destroy(&w);
        rdx_qkr_fail(&err, "encode failed");
    }
    ctx->bytes = rdx_qk_writer_detach(&w, &nbytes);
    if (!ctx->bytes) Rf_error("Rducks quack codec: out of memory encoding chunk");
    out = Rf_allocVector(RAWSXP, (R_xlen_t)nbytes);
    memcpy(RAW(out), ctx->bytes, nbytes);
    return out;
}

SEXP RDUCKS_quack_encode_chunk(SEXP rows_sexp, SEXP types_spec, SEXP columns) {
    rdx_qkr_encode_ctx ctx = {0};
    R_xlen_t ncolumns;
    uint64_t rows;
    SEXP cont, res;

    if (TYPEOF(types_spec) != VECSXP || TYPEOF(columns) != VECSXP) {
        Rf_error("Rducks quack codec: types and columns must be lists");
    }
    ncolumns = Rf_xlength(types_spec);
    if (Rf_xlength(columns) != ncolumns) {
        Rf_error("Rducks quack codec: types and columns lengths disagree");
    }
    {
        double r = Rf_asReal(rows_sexp);
        if (ISNA(r) || r < 0 || r > (double)RDX_QK_MAX_ROWS) {
            Rf_error("Rducks quack codec: invalid row count");
        }
        rows = (uint64_t)r;
    }
    ctx.chunk = rdx_qk_chunk_new(rows, (uint32_t)ncolumns);
    if (!ctx.chunk) Rf_error("Rducks quack codec: out of memory building chunk");
    ctx.rows = rows;
    ctx.types_spec = types_spec;
    ctx.columns = columns;
    cont = PROTECT(R_MakeUnwindCont());
    res = R_UnwindProtect(rdx_qkr_encode_body, &ctx, rdx_qkr_encode_cleanup, &ctx, cont);
    UNPROTECT(1);
    return res;
}

/* Materializing R columns from the decoded chunk can Rf_error() (allocation,
 * malformed storage), so the chunk is freed by an R_UnwindProtect cleanup that
 * runs on both normal return and unwinding. */
typedef struct {
    rdx_qk_chunk *chunk;   /* freed by cleanup */
    SEXP expected;         /* declared wire specs to validate against, or R_NilValue */
} rdx_qkr_decode_ctx;

static void rdx_qkr_decode_cleanup(void *data, Rboolean jump) {
    rdx_qkr_decode_ctx *ctx = (rdx_qkr_decode_ctx *)data;
    (void)jump;
    if (ctx->chunk) { rdx_qk_chunk_free(ctx->chunk); ctx->chunk = NULL; }
}

static SEXP rdx_qkr_decode_body(void *data) {
    rdx_qkr_decode_ctx *ctx = (rdx_qkr_decode_ctx *)data;
    rdx_qk_chunk *chunk = ctx->chunk;
    SEXP out, types, columns;
    static const char *fields[] = {"rows", "types", "columns"};
    uint32_t i;
    /* When the caller declares the expected wire types, reject any payload whose
     * decoded types disagree before materializing a single column. The comparison
     * reuses rdx_qk_type_equal -- the same canonical type equality the native
     * result-writeback path uses -- so both decode boundaries stay consistent. */
    if (ctx->expected != R_NilValue) {
        if (TYPEOF(ctx->expected) != VECSXP ||
            (uint32_t)Rf_xlength(ctx->expected) != chunk->ncolumns) {
            Rf_error("Rducks wire payload column count disagrees with the declared signature");
        }
        for (i = 0; i < chunk->ncolumns; i++) {
            rdx_qk_type *exp = rdx_qkr_type_from_spec(VECTOR_ELT(ctx->expected, (R_xlen_t)i), 0);
            int eq = rdx_qk_type_equal(exp, chunk->types[i]);
            rdx_qk_type_free(exp);
            if (!eq) {
                Rf_error("Rducks wire payload type for column %u disagrees with the declared signature",
                         (unsigned)(i + 1));
            }
        }
    }
    out = PROTECT(rdx_qkr_named_list(3, fields));
    SET_VECTOR_ELT(out, 0, Rf_ScalarReal((double)chunk->rows));
    types = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)chunk->ncolumns));
    columns = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)chunk->ncolumns));
    for (i = 0; i < chunk->ncolumns; i++) {
        SET_VECTOR_ELT(types, (R_xlen_t)i, rdx_qkr_spec_from_type(chunk->types[i]));
        SET_VECTOR_ELT(columns, (R_xlen_t)i, rdx_qkr_column_from_vector(chunk->columns[i], 0));
    }
    SET_VECTOR_ELT(out, 1, types);
    SET_VECTOR_ELT(out, 2, columns);
    UNPROTECT(3);
    return out;
}

SEXP RDUCKS_quack_decode_chunk(SEXP payload, SEXP expected) {
    rdx_qk_reader r;
    rdx_qk_error err = {{0}};
    rdx_qkr_decode_ctx ctx = {0};
    SEXP cont, res;

    if (TYPEOF(payload) != RAWSXP) Rf_error("Rducks quack codec: payload must be a raw vector");
    ctx.expected = expected;
    rdx_qk_reader_init(&r, RAW(payload), (size_t)Rf_xlength(payload));
    if (!rdx_qk_chunk_decode(&r, &ctx.chunk, &err)) {
        rdx_qkr_fail(&err, "decode failed");
    }
    if (r.pos != r.size) {
        rdx_qk_chunk_free(ctx.chunk);
        Rf_error("Rducks quack codec: %zu trailing bytes after the chunk payload", r.size - r.pos);
    }
    cont = PROTECT(R_MakeUnwindCont());
    res = R_UnwindProtect(rdx_qkr_decode_body, &ctx, rdx_qkr_decode_cleanup, &ctx, cont);
    UNPROTECT(1);
    return res;
}
