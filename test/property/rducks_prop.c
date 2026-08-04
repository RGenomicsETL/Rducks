#include "quack_core.h"
#include "theft.h"

#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PROP_DEFAULT_TRIALS 1000u
#define PROP_DEFAULT_SEED UINT64_C(0x726475636b735051)
#define PROP_MAX_RANDOM_BYTES 512u
#define PROP_MAX_ROWS 32u
#define PROP_DATA_BYTES 256u

struct prop_bytes {
    size_t len;
    uint8_t data[];
};

struct prop_chunk_case {
    uint8_t kind;
    uint8_t rows;
    uint8_t validity;
    uint8_t data[PROP_DATA_BYTES];
};

static uint64_t prop_random_bounded(struct theft *theft, uint64_t limit) {
    if (limit <= 1u) return 0u;
    return theft_random_bits(theft, 16) % limit;
}

static size_t prop_env_size(const char *name, size_t fallback) {
    const char *value = getenv(name);
    char *end = NULL;
    unsigned long long parsed;

    if (!value || !value[0]) return fallback;
    errno = 0;
    parsed = strtoull(value, &end, 0);
    if (errno || !end || *end || parsed == 0u || parsed > SIZE_MAX) return fallback;
    return (size_t)parsed;
}

static theft_seed prop_env_seed(void) {
    const char *value = getenv("RDUCKS_PROP_SEED");
    char *end = NULL;
    unsigned long long parsed;

    if (!value || !value[0]) return (theft_seed)PROP_DEFAULT_SEED;
    errno = 0;
    parsed = strtoull(value, &end, 0);
    if (errno || !end || *end) return (theft_seed)PROP_DEFAULT_SEED;
    return (theft_seed)parsed;
}

static enum theft_alloc_res prop_bytes_alloc(struct theft *theft, void *env,
                                             void **instance) {
    struct prop_bytes *bytes;
    size_t len = (size_t)prop_random_bounded(theft, PROP_MAX_RANDOM_BYTES + 1u);
    size_t i;

    (void)env;
    bytes = (struct prop_bytes *)malloc(sizeof(*bytes) + len);
    if (!bytes) return THEFT_ALLOC_ERROR;
    bytes->len = len;
    for (i = 0; i < len; i++) bytes->data[i] = (uint8_t)theft_random_bits(theft, 8);
    *instance = bytes;
    return THEFT_ALLOC_OK;
}

static enum theft_alloc_res prop_chunk_alloc(struct theft *theft, void *env,
                                             void **instance) {
    struct prop_chunk_case *input;
    size_t i;

    (void)env;
    input = (struct prop_chunk_case *)malloc(sizeof(*input));
    if (!input) return THEFT_ALLOC_ERROR;
    input->kind = (uint8_t)prop_random_bounded(theft, 3u);
    input->rows = (uint8_t)prop_random_bounded(theft, PROP_MAX_ROWS + 1u);
    input->validity = (uint8_t)theft_random_bits(theft, 1);
    for (i = 0; i < sizeof(input->data); i++) {
        input->data[i] = (uint8_t)theft_random_bits(theft, 8);
    }
    *instance = input;
    return THEFT_ALLOC_OK;
}

static void prop_free(void *instance, void *env) {
    (void)env;
    free(instance);
}

static void prop_bytes_print(FILE *out, const void *instance, void *env) {
    const struct prop_bytes *bytes = (const struct prop_bytes *)instance;
    size_t i;

    (void)env;
    fprintf(out, "len=%zu", bytes->len);
    for (i = 0; i < bytes->len; i++) fprintf(out, "%s%02x", i ? "" : " bytes=", bytes->data[i]);
    fputc('\n', out);
}

static void prop_chunk_print(FILE *out, const void *instance, void *env) {
    const struct prop_chunk_case *input = (const struct prop_chunk_case *)instance;

    (void)env;
    fprintf(out, "kind=%u rows=%u validity=%u data0=%02x%02x%02x%02x\n",
            (unsigned)input->kind, (unsigned)input->rows,
            (unsigned)input->validity, input->data[0], input->data[1],
            input->data[2], input->data[3]);
}

static struct theft_type_info prop_bytes_info = {
    .alloc = prop_bytes_alloc,
    .free = prop_free,
    .print = prop_bytes_print,
    .autoshrink_config = {.enable = true},
};

static struct theft_type_info prop_chunk_info = {
    .alloc = prop_chunk_alloc,
    .free = prop_free,
    .print = prop_chunk_print,
    .autoshrink_config = {.enable = true},
};

static int prop_apply_validity(rdx_qk_vector *vector,
                               const struct prop_chunk_case *input) {
    uint64_t row;

    if (!input->validity || !rdx_qk_vector_alloc_validity(vector)) {
        return input->validity ? 0 : 1;
    }
    for (row = 0; row < vector->rows; row++) {
        if (!(input->data[row % PROP_DATA_BYTES] & 1u)) {
            rdx_qk_vector_set_null(vector, row);
        }
    }
    return 1;
}

static rdx_qk_chunk *prop_build_integer(const struct prop_chunk_case *input) {
    rdx_qk_chunk *chunk = rdx_qk_chunk_new(input->rows, 1u);
    rdx_qk_type *type = NULL;
    rdx_qk_vector *vector = NULL;
    size_t i;

    if (!chunk) return NULL;
    type = rdx_qk_type_new(RDX_QK_LTYPE_INTEGER);
    vector = rdx_qk_vector_new(type, input->rows);
    if (!type || !vector || !rdx_qk_vector_alloc_fixed(vector) ||
        !prop_apply_validity(vector, input)) goto fail;
    for (i = 0; i < vector->data_size; i++) vector->data[i] = input->data[i % PROP_DATA_BYTES];
    chunk->types[0] = type;
    chunk->columns[0] = vector;
    return chunk;

fail:
    rdx_qk_vector_free(vector);
    rdx_qk_type_free(type);
    rdx_qk_chunk_free(chunk);
    return NULL;
}

static rdx_qk_chunk *prop_build_varchar(const struct prop_chunk_case *input) {
    rdx_qk_chunk *chunk = rdx_qk_chunk_new(input->rows, 1u);
    rdx_qk_type *type = NULL;
    rdx_qk_vector *vector = NULL;
    uint64_t row;
    size_t pool_size = 0u;
    size_t cursor = 0u;

    if (!chunk) return NULL;
    for (row = 0; row < input->rows; row++) pool_size += input->data[row] % 9u;
    type = rdx_qk_type_new(RDX_QK_LTYPE_VARCHAR);
    vector = rdx_qk_vector_new(type, input->rows);
    if (!type || !vector || !rdx_qk_vector_alloc_strings(vector, pool_size) ||
        !prop_apply_validity(vector, input)) goto fail;
    for (row = 0; row < input->rows; row++) {
        size_t len = input->data[row] % 9u;
        size_t i;
        vector->str_offsets[row] = cursor;
        for (i = 0; i < len; i++) {
            vector->str_pool[cursor++] = input->data[(row * 11u + i) % PROP_DATA_BYTES];
        }
    }
    vector->str_offsets[input->rows] = cursor;
    chunk->types[0] = type;
    chunk->columns[0] = vector;
    return chunk;

fail:
    rdx_qk_vector_free(vector);
    rdx_qk_type_free(type);
    rdx_qk_chunk_free(chunk);
    return NULL;
}

static rdx_qk_chunk *prop_build_list(const struct prop_chunk_case *input) {
    rdx_qk_chunk *chunk = rdx_qk_chunk_new(input->rows, 1u);
    rdx_qk_type *list_type = NULL;
    rdx_qk_type *child_type = NULL;
    rdx_qk_vector *list = NULL;
    rdx_qk_vector *child = NULL;
    uint64_t row;
    uint64_t child_rows = 0u;
    size_t i;

    if (!chunk) return NULL;
    for (row = 0; row < input->rows; row++) child_rows += input->data[row] % 4u;
    list_type = rdx_qk_type_new(RDX_QK_LTYPE_LIST);
    child_type = rdx_qk_type_new(RDX_QK_LTYPE_INTEGER);
    if (!list_type || !child_type ||
        !rdx_qk_type_add_child(list_type, child_type, "child")) goto fail;
    child_type = NULL;
    list = rdx_qk_vector_new(list_type, input->rows);
    if (!list || !rdx_qk_vector_alloc_list(list, child_rows) ||
        !prop_apply_validity(list, input)) goto fail;
    list->children = (rdx_qk_vector **)calloc(1u, sizeof(*list->children));
    if (!list->children) goto fail;
    child = rdx_qk_vector_new(list_type->children[0], child_rows);
    if (!child || !rdx_qk_vector_alloc_fixed(child)) goto fail;
    for (i = 0; i < child->data_size; i++) child->data[i] = input->data[(i + 37u) % PROP_DATA_BYTES];
    list->children[0] = child;
    list->nchildren = 1u;
    child = NULL;
    child_rows = 0u;
    for (row = 0; row < input->rows; row++) {
        uint64_t len = input->data[row] % 4u;
        list->list_offsets[row] = child_rows;
        list->list_lengths[row] = len;
        child_rows += len;
    }
    chunk->types[0] = list_type;
    chunk->columns[0] = list;
    return chunk;

fail:
    rdx_qk_vector_free(child);
    rdx_qk_vector_free(list);
    rdx_qk_type_free(child_type);
    rdx_qk_type_free(list_type);
    rdx_qk_chunk_free(chunk);
    return NULL;
}

static rdx_qk_chunk *prop_build_chunk(const struct prop_chunk_case *input) {
    switch (input->kind) {
    case 0: return prop_build_integer(input);
    case 1: return prop_build_varchar(input);
    default: return prop_build_list(input);
    }
}

static int prop_vectors_equal(const rdx_qk_vector *left,
                              const rdx_qk_vector *right) {
    uint64_t row;
    size_t width;

    if (!left || !right || left->rows != right->rows ||
        !rdx_qk_type_equal(left->type, right->type)) return 0;
    for (row = 0; row < left->rows; row++) {
        if (rdx_qk_vector_row_is_valid(left, row) !=
            rdx_qk_vector_row_is_valid(right, row)) return 0;
    }
    width = rdx_qk_type_fixed_width(left->type);
    if (width) {
        return left->data_size == right->data_size &&
               memcmp(left->data, right->data, left->data_size) == 0;
    }
    if (left->type->id == RDX_QK_LTYPE_VARCHAR) {
        return left->str_pool_size == right->str_pool_size &&
               memcmp(left->str_offsets, right->str_offsets,
                      ((size_t)left->rows + 1u) * sizeof(uint64_t)) == 0 &&
               memcmp(left->str_pool, right->str_pool, left->str_pool_size) == 0;
    }
    if (left->type->id == RDX_QK_LTYPE_LIST) {
        return left->list_child_rows == right->list_child_rows &&
               memcmp(left->list_offsets, right->list_offsets,
                      (size_t)left->rows * sizeof(uint64_t)) == 0 &&
               memcmp(left->list_lengths, right->list_lengths,
                      (size_t)left->rows * sizeof(uint64_t)) == 0 &&
               left->nchildren == 1u && right->nchildren == 1u &&
               prop_vectors_equal(left->children[0], right->children[0]);
    }
    return 0;
}

static int prop_chunks_equal(const rdx_qk_chunk *left,
                             const rdx_qk_chunk *right) {
    uint32_t column;

    if (!left || !right || left->rows != right->rows ||
        left->ncolumns != right->ncolumns) return 0;
    for (column = 0; column < left->ncolumns; column++) {
        if (!rdx_qk_type_equal(left->types[column], right->types[column]) ||
            !prop_vectors_equal(left->columns[column], right->columns[column])) return 0;
    }
    return 1;
}

static int prop_encode_chunk(const rdx_qk_chunk *chunk, uint8_t **data,
                             size_t *size) {
    rdx_qk_writer writer;
    rdx_qk_error error = {{0}};

    rdx_qk_writer_init(&writer);
    if (!rdx_qk_chunk_encode(&writer, chunk, &error)) {
        rdx_qk_writer_destroy(&writer);
        return 0;
    }
    *data = rdx_qk_writer_detach(&writer, size);
    rdx_qk_writer_destroy(&writer);
    return *data != NULL;
}

static enum theft_trial_res prop_chunk_roundtrip(struct theft *theft, void *arg) {
    const struct prop_chunk_case *input = (const struct prop_chunk_case *)arg;
    rdx_qk_chunk *source = NULL;
    rdx_qk_chunk *decoded = NULL;
    rdx_qk_reader reader;
    rdx_qk_error error = {{0}};
    uint8_t *encoded = NULL;
    size_t encoded_size = 0u;
    enum theft_trial_res result = THEFT_TRIAL_FAIL;

    (void)theft;
    source = prop_build_chunk(input);
    if (!source || !prop_encode_chunk(source, &encoded, &encoded_size)) {
        result = THEFT_TRIAL_ERROR;
        goto done;
    }
    rdx_qk_reader_init(&reader, encoded, encoded_size);
    if (rdx_qk_chunk_decode(&reader, &decoded, &error) &&
        reader.pos == reader.size && prop_chunks_equal(source, decoded)) {
        result = THEFT_TRIAL_PASS;
    }

done:
    free(encoded);
    rdx_qk_chunk_free(decoded);
    rdx_qk_chunk_free(source);
    return result;
}

static enum theft_trial_res prop_chunk_truncation(struct theft *theft, void *arg) {
    const struct prop_chunk_case *input = (const struct prop_chunk_case *)arg;
    rdx_qk_chunk *source = NULL;
    uint8_t *encoded = NULL;
    size_t encoded_size = 0u;
    size_t prefix;
    enum theft_trial_res result = THEFT_TRIAL_PASS;

    (void)theft;
    source = prop_build_chunk(input);
    if (!source || !prop_encode_chunk(source, &encoded, &encoded_size)) {
        result = THEFT_TRIAL_ERROR;
        goto done;
    }
    for (prefix = 0; prefix < encoded_size; prefix++) {
        rdx_qk_reader reader;
        rdx_qk_chunk *decoded = NULL;
        rdx_qk_error error = {{0}};
        rdx_qk_reader_init(&reader, encoded, prefix);
        if (rdx_qk_chunk_decode(&reader, &decoded, &error)) {
            rdx_qk_chunk_free(decoded);
            result = THEFT_TRIAL_FAIL;
            break;
        }
    }

done:
    free(encoded);
    rdx_qk_chunk_free(source);
    return result;
}

static enum theft_trial_res prop_random_bytes_decode(struct theft *theft, void *arg) {
    const struct prop_bytes *bytes = (const struct prop_bytes *)arg;
    rdx_qk_reader reader;
    rdx_qk_chunk *chunk = NULL;
    rdx_qk_error error = {{0}};
    uint8_t *encoded = NULL;
    size_t encoded_size = 0u;
    enum theft_trial_res result = THEFT_TRIAL_PASS;

    (void)theft;
    rdx_qk_reader_init(&reader, bytes->data, bytes->len);
    if (!rdx_qk_chunk_decode(&reader, &chunk, &error)) return THEFT_TRIAL_PASS;
    if (!prop_encode_chunk(chunk, &encoded, &encoded_size)) {
        result = THEFT_TRIAL_FAIL;
    } else {
        rdx_qk_reader second_reader;
        rdx_qk_chunk *second = NULL;
        rdx_qk_reader_init(&second_reader, encoded, encoded_size);
        if (!rdx_qk_chunk_decode(&second_reader, &second, &error) ||
            second_reader.pos != second_reader.size ||
            !prop_chunks_equal(chunk, second)) result = THEFT_TRIAL_FAIL;
        rdx_qk_chunk_free(second);
    }
    free(encoded);
    rdx_qk_chunk_free(chunk);
    return result;
}

static enum theft_run_res prop_run(const char *name, theft_propfun1 *property,
                                   const struct theft_type_info *type) {
    struct theft_run_config config;

    memset(&config, 0, sizeof(config));
    config.name = name;
    config.prop1 = property;
    config.type_info[0] = type;
    config.trials = prop_env_size("RDUCKS_PROP_TRIALS", PROP_DEFAULT_TRIALS);
    config.seed = prop_env_seed();
    return theft_run(&config);
}

int main(void) {
    int failed = 0;

    failed |= prop_run("accepted Quack chunks round-trip", prop_chunk_roundtrip,
                       &prop_chunk_info) != THEFT_RUN_PASS;
    failed |= prop_run("valid Quack chunk prefixes are rejected", prop_chunk_truncation,
                       &prop_chunk_info) != THEFT_RUN_PASS;
    failed |= prop_run("random Quack bytes reject or canonicalize", prop_random_bytes_decode,
                       &prop_bytes_info) != THEFT_RUN_PASS;
    return failed ? EXIT_FAILURE : EXIT_SUCCESS;
}
