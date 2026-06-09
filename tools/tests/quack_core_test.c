/* Standalone unit tests for the Rducks quack wire core. */
#include "src/quack_core.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
#define CHECK(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); failures++; } } while (0)

static void test_leb128_roundtrip(void) {
    uint64_t uvals[] = {0, 1, 127, 128, 300, 16383, 16384, 0xffffffffu, UINT64_MAX};
    int64_t svals[] = {0, 1, -1, 63, -64, 64, -65, 127, -128, INT64_MAX, INT64_MIN};
    size_t i;
    for (i = 0; i < sizeof(uvals)/sizeof(uvals[0]); i++) {
        rdx_qk_writer w; rdx_qk_reader r; rdx_qk_error e; uint64_t out; size_t n; uint8_t *buf;
        rdx_qk_writer_init(&w);
        rdx_qk_write_uleb(&w, uvals[i]);
        buf = rdx_qk_writer_detach(&w, &n);
        rdx_qk_reader_init(&r, buf, n);
        CHECK(rdx_qk_read_uleb(&r, &out, &e), "uleb decode");
        CHECK(out == uvals[i], "uleb value");
        CHECK(r.pos == r.size, "uleb consumed");
        free(buf);
    }
    for (i = 0; i < sizeof(svals)/sizeof(svals[0]); i++) {
        rdx_qk_writer w; rdx_qk_reader r; rdx_qk_error e; int64_t out; size_t n; uint8_t *buf;
        rdx_qk_writer_init(&w);
        rdx_qk_write_sleb(&w, svals[i]);
        buf = rdx_qk_writer_detach(&w, &n);
        rdx_qk_reader_init(&r, buf, n);
        CHECK(rdx_qk_read_sleb(&r, &out, &e), "sleb decode");
        CHECK(out == svals[i], "sleb value");
        free(buf);
    }
    /* fixture: 300 = 0xAC 0x02 (LEB128 reference vector) */
    {
        rdx_qk_writer w; size_t n; uint8_t *buf;
        rdx_qk_writer_init(&w);
        rdx_qk_write_uleb(&w, 300);
        buf = rdx_qk_writer_detach(&w, &n);
        CHECK(n == 2 && buf[0] == 0xAC && buf[1] == 0x02, "uleb 300 fixture");
        free(buf);
    }
    /* fixture: sleb(-2) = 0x7E */
    {
        rdx_qk_writer w; size_t n; uint8_t *buf;
        rdx_qk_writer_init(&w);
        rdx_qk_write_sleb(&w, -2);
        buf = rdx_qk_writer_detach(&w, &n);
        CHECK(n == 1 && buf[0] == 0x7E, "sleb -2 fixture");
        free(buf);
    }
}

static void test_uleb_overflow_rejected(void) {
    /* 10 continuation bytes => > 64 bits */
    uint8_t bad[11];
    rdx_qk_reader r; rdx_qk_error e; uint64_t out;
    memset(bad, 0xff, sizeof(bad));
    bad[10] = 0x7f;
    rdx_qk_reader_init(&r, bad, sizeof(bad));
    CHECK(!rdx_qk_read_uleb(&r, &out, &e), "uleb overflow rejected");
}

static rdx_qk_type *mk_scalar(uint32_t id) { return rdx_qk_type_new(id); }

static void test_type_roundtrip(void) {
    /* DECIMAL(12, 3) */
    rdx_qk_type *dec = mk_scalar(RDX_QK_LTYPE_DECIMAL);
    rdx_qk_type *out = NULL;
    rdx_qk_writer w; rdx_qk_reader r; rdx_qk_error e; size_t n; uint8_t *buf;
    dec->width = 12; dec->scale = 3;
    rdx_qk_writer_init(&w);
    CHECK(rdx_qk_type_encode(&w, dec, &e), "decimal encode");
    buf = rdx_qk_writer_detach(&w, &n);
    rdx_qk_reader_init(&r, buf, n);
    CHECK(rdx_qk_type_decode(&r, &out, &e), "decimal decode");
    CHECK(out && rdx_qk_type_equal(dec, out), "decimal equal");
    CHECK(r.pos == r.size, "decimal consumed");
    free(buf); rdx_qk_type_free(dec); rdx_qk_type_free(out);

    /* STRUCT(a INTEGER, b LIST(VARCHAR)) */
    {
        rdx_qk_type *st = mk_scalar(RDX_QK_LTYPE_STRUCT);
        rdx_qk_type *lst = mk_scalar(RDX_QK_LTYPE_LIST);
        rdx_qk_type *o2 = NULL;
        CHECK(rdx_qk_type_add_child(lst, mk_scalar(RDX_QK_LTYPE_VARCHAR), "child"), "list child");
        CHECK(rdx_qk_type_add_child(st, mk_scalar(RDX_QK_LTYPE_INTEGER), "a"), "struct a");
        CHECK(rdx_qk_type_add_child(st, lst, "b"), "struct b");
        rdx_qk_writer_init(&w);
        CHECK(rdx_qk_type_encode(&w, st, &e), "struct encode");
        buf = rdx_qk_writer_detach(&w, &n);
        rdx_qk_reader_init(&r, buf, n);
        CHECK(rdx_qk_type_decode(&r, &o2, &e), "struct decode");
        CHECK(o2 && rdx_qk_type_equal(st, o2), "struct equal");
        free(buf); rdx_qk_type_free(st); rdx_qk_type_free(o2);
    }

    /* ENUM('lo','hi'), ARRAY(DOUBLE, 4) */
    {
        const char *labels[] = {"lo", "hi"};
        rdx_qk_type *en = mk_scalar(RDX_QK_LTYPE_ENUM);
        rdx_qk_type *ar = mk_scalar(RDX_QK_LTYPE_ARRAY);
        rdx_qk_type *o3 = NULL, *o4 = NULL;
        CHECK(rdx_qk_type_set_enum_labels(en, labels, 2), "enum labels");
        ar->array_size = 4;
        CHECK(rdx_qk_type_add_child(ar, mk_scalar(RDX_QK_LTYPE_DOUBLE), "child"), "array child");
        rdx_qk_writer_init(&w);
        CHECK(rdx_qk_type_encode(&w, en, &e), "enum encode");
        buf = rdx_qk_writer_detach(&w, &n);
        rdx_qk_reader_init(&r, buf, n);
        CHECK(rdx_qk_type_decode(&r, &o3, &e), "enum decode");
        CHECK(o3 && rdx_qk_type_equal(en, o3), "enum equal");
        free(buf);
        rdx_qk_writer_init(&w);
        CHECK(rdx_qk_type_encode(&w, ar, &e), "array encode");
        buf = rdx_qk_writer_detach(&w, &n);
        rdx_qk_reader_init(&r, buf, n);
        CHECK(rdx_qk_type_decode(&r, &o4, &e), "array decode");
        CHECK(o4 && rdx_qk_type_equal(ar, o4), "array equal");
        free(buf);
        rdx_qk_type_free(en); rdx_qk_type_free(ar); rdx_qk_type_free(o3); rdx_qk_type_free(o4);
    }
}

static void test_chunk_roundtrip(void) {
    /* 3 rows: INTEGER with a NULL, VARCHAR, LIST(INTEGER) */
    rdx_qk_chunk *c = rdx_qk_chunk_new(3, 3);
    rdx_qk_chunk *out = NULL;
    rdx_qk_writer w; rdx_qk_reader r; rdx_qk_error e; size_t n; uint8_t *buf;
    int32_t *ints;
    uint64_t row;

    c->types[0] = mk_scalar(RDX_QK_LTYPE_INTEGER);
    c->types[1] = mk_scalar(RDX_QK_LTYPE_VARCHAR);
    c->types[2] = mk_scalar(RDX_QK_LTYPE_LIST);
    rdx_qk_type_add_child(c->types[2], mk_scalar(RDX_QK_LTYPE_INTEGER), "child");

    c->columns[0] = rdx_qk_vector_new(c->types[0], 3);
    CHECK(rdx_qk_vector_alloc_fixed(c->columns[0]), "int alloc");
    ints = (int32_t *)c->columns[0]->data;
    ints[0] = 7; ints[1] = 0; ints[2] = -42;
    CHECK(rdx_qk_vector_alloc_validity(c->columns[0]), "int validity");
    rdx_qk_vector_set_null(c->columns[0], 1);

    c->columns[1] = rdx_qk_vector_new(c->types[1], 3);
    {
        const char *vals[] = {"alpha", "", "gamma"};
        size_t pool = 0, fill = 0;
        size_t i;
        for (i = 0; i < 3; i++) pool += strlen(vals[i]);
        CHECK(rdx_qk_vector_alloc_strings(c->columns[1], pool), "str alloc");
        for (i = 0; i < 3; i++) {
            size_t l = strlen(vals[i]);
            memcpy(c->columns[1]->str_pool + fill, vals[i], l);
            c->columns[1]->str_offsets[i] = fill;
            fill += l;
        }
        c->columns[1]->str_offsets[3] = fill;
    }

    c->columns[2] = rdx_qk_vector_new(c->types[2], 3);
    CHECK(rdx_qk_vector_alloc_list(c->columns[2], 4), "list alloc");
    c->columns[2]->list_offsets[0] = 0; c->columns[2]->list_lengths[0] = 2;
    c->columns[2]->list_offsets[1] = 2; c->columns[2]->list_lengths[1] = 0;
    c->columns[2]->list_offsets[2] = 2; c->columns[2]->list_lengths[2] = 2;
    c->columns[2]->children = (rdx_qk_vector **)calloc(1, sizeof(rdx_qk_vector *));
    c->columns[2]->children[0] = rdx_qk_vector_new(c->types[2]->children[0], 4);
    c->columns[2]->nchildren = 1;
    CHECK(rdx_qk_vector_alloc_fixed(c->columns[2]->children[0]), "list child alloc");
    {
        int32_t *cv = (int32_t *)c->columns[2]->children[0]->data;
        cv[0] = 1; cv[1] = 2; cv[2] = 3; cv[3] = 4;
    }

    rdx_qk_writer_init(&w);
    CHECK(rdx_qk_chunk_encode(&w, c, &e), "chunk encode");
    buf = rdx_qk_writer_detach(&w, &n);
    CHECK(buf && n > 0, "chunk bytes");
    rdx_qk_reader_init(&r, buf, n);
    if (!rdx_qk_chunk_decode(&r, &out, &e)) {
        printf("decode error: %s\n", e.message);
    }
    CHECK(out != NULL, "chunk decode");
    if (out) {
        CHECK(out->rows == 3 && out->ncolumns == 3, "chunk shape");
        CHECK(rdx_qk_type_equal(out->types[0], c->types[0]), "chunk type 0");
        CHECK(rdx_qk_type_equal(out->types[2], c->types[2]), "chunk type 2");
        CHECK(!rdx_qk_vector_row_is_valid(out->columns[0], 1), "null row preserved");
        CHECK(rdx_qk_vector_row_is_valid(out->columns[0], 0), "valid row preserved");
        {
            const int32_t *iv = (const int32_t *)out->columns[0]->data;
            CHECK(iv[0] == 7 && iv[2] == -42, "int payload");
        }
        {
            const rdx_qk_vector *sv = out->columns[1];
            uint64_t a = sv->str_offsets[0], b = sv->str_offsets[1];
            CHECK(b - a == 5 && memcmp(sv->str_pool + a, "alpha", 5) == 0, "string row 0");
            CHECK(sv->str_offsets[2] == sv->str_offsets[1], "empty string row 1");
        }
        {
            const rdx_qk_vector *lv = out->columns[2];
            CHECK(lv->list_child_rows == 4, "list child rows");
            CHECK(lv->list_lengths[0] == 2 && lv->list_lengths[1] == 0, "list entries");
            CHECK(lv->nchildren == 1 && lv->children[0]->rows == 4, "list child decoded");
        }
        CHECK(r.pos == r.size, "chunk fully consumed");
    }
    (void)row;
    free(buf);
    rdx_qk_chunk_free(c);
    rdx_qk_chunk_free(out);
}

static void test_truncation_rejected(void) {
    rdx_qk_chunk *c = rdx_qk_chunk_new(1, 1);
    rdx_qk_writer w; rdx_qk_error e; size_t n; uint8_t *buf;
    c->types[0] = mk_scalar(RDX_QK_LTYPE_DOUBLE);
    c->columns[0] = rdx_qk_vector_new(c->types[0], 1);
    rdx_qk_vector_alloc_fixed(c->columns[0]);
    rdx_qk_writer_init(&w);
    rdx_qk_chunk_encode(&w, c, &e);
    buf = rdx_qk_writer_detach(&w, &n);
    {
        size_t cut;
        for (cut = 0; cut < n; cut++) {
            rdx_qk_reader r; rdx_qk_chunk *out = NULL;
            rdx_qk_reader_init(&r, buf, cut);
            if (rdx_qk_chunk_decode(&r, &out, &e)) {
                printf("FAIL: truncated payload at %zu decoded\n", cut);
                failures++;
                rdx_qk_chunk_free(out);
            }
        }
    }
    free(buf);
    rdx_qk_chunk_free(c);
}

int main(void) {
    test_leb128_roundtrip();
    test_uleb_overflow_rejected();
    test_type_roundtrip();
    test_chunk_roundtrip();
    test_truncation_rejected();
    if (failures) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("all quack core tests passed\n");
    return 0;
}
