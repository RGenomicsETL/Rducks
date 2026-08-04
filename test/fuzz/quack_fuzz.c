#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "quack_core.h"

static void fuzz_type(const uint8_t *data, size_t size) {
    rdx_qk_reader reader;
    rdx_qk_type *type = NULL;
    rdx_qk_error error = {{0}};

    rdx_qk_reader_init(&reader, data, size);
    if (rdx_qk_type_decode(&reader, &type, &error)) {
        rdx_qk_writer writer;
        rdx_qk_reader encoded_reader;
        rdx_qk_type *decoded = NULL;
        uint8_t *encoded;
        size_t encoded_size = 0;

        rdx_qk_writer_init(&writer);
        if (!rdx_qk_type_encode(&writer, type, &error)) abort();
        encoded = rdx_qk_writer_detach(&writer, &encoded_size);
        rdx_qk_writer_destroy(&writer);
        if (!encoded) abort();

        rdx_qk_reader_init(&encoded_reader, encoded, encoded_size);
        if (!rdx_qk_type_decode(&encoded_reader, &decoded, &error) ||
            encoded_reader.pos != encoded_reader.size ||
            !rdx_qk_type_equal(type, decoded)) {
            abort();
        }
        free(encoded);
        rdx_qk_type_free(decoded);
        rdx_qk_type_free(type);
    }
}

static void fuzz_chunk(const uint8_t *data, size_t size) {
    rdx_qk_reader reader;
    rdx_qk_chunk *chunk = NULL;
    rdx_qk_error error = {{0}};

    rdx_qk_reader_init(&reader, data, size);
    if (rdx_qk_chunk_decode(&reader, &chunk, &error)) {
        rdx_qk_writer writer;
        rdx_qk_reader encoded_reader;
        rdx_qk_chunk *decoded = NULL;
        uint8_t *encoded;
        size_t encoded_size = 0;
        uint32_t column;

        rdx_qk_writer_init(&writer);
        if (!rdx_qk_chunk_encode(&writer, chunk, &error)) abort();
        encoded = rdx_qk_writer_detach(&writer, &encoded_size);
        rdx_qk_writer_destroy(&writer);
        if (!encoded) abort();

        rdx_qk_reader_init(&encoded_reader, encoded, encoded_size);
        if (!rdx_qk_chunk_decode(&encoded_reader, &decoded, &error) ||
            encoded_reader.pos != encoded_reader.size ||
            decoded->rows != chunk->rows ||
            decoded->ncolumns != chunk->ncolumns) {
            abort();
        }
        for (column = 0; column < chunk->ncolumns; column++) {
            if (!rdx_qk_type_equal(chunk->types[column], decoded->types[column])) abort();
        }
        free(encoded);
        rdx_qk_chunk_free(decoded);
        rdx_qk_chunk_free(chunk);
    }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    fuzz_type(data, size);
    fuzz_chunk(data, size);
    return 0;
}
