/* Shared helpers around the vendored nanoarrow IPC writer/reader. */
#ifndef RDUCKS_VENDOR_IPC_HELPERS_H
#define RDUCKS_VENDOR_IPC_HELPERS_H

#include <limits.h>

#ifndef RDUCKS_IPC_ERROR_SIZE
#define RDUCKS_IPC_ERROR_SIZE 512
#endif

typedef struct rducks_borrowed_array_stream_private {
    const struct ArrowSchema *schema;
    const struct ArrowArray *array;
    int emitted;
    char error[RDUCKS_IPC_ERROR_SIZE];
} rducks_borrowed_array_stream_private_t;

static void rducks_borrowed_array_release(struct ArrowArray *array) {
    if (array) array->release = NULL;
}

static int rducks_borrowed_array_stream_get_schema(struct ArrowArrayStream *stream,
                                                   struct ArrowSchema *out) {
    rducks_borrowed_array_stream_private_t *private_data;
    if (!stream || !out || !stream->private_data) return EINVAL;
    private_data = (rducks_borrowed_array_stream_private_t *)stream->private_data;
    if (!private_data->schema || !private_data->schema->release) {
        snprintf(private_data->error, sizeof(private_data->error), "borrowed Arrow stream schema is invalid");
        return EINVAL;
    }
    return ArrowSchemaDeepCopy(private_data->schema, out);
}

static int rducks_borrowed_array_stream_get_next(struct ArrowArrayStream *stream,
                                                 struct ArrowArray *out) {
    rducks_borrowed_array_stream_private_t *private_data;
    if (!stream || !out || !stream->private_data) return EINVAL;
    private_data = (rducks_borrowed_array_stream_private_t *)stream->private_data;
    memset(out, 0, sizeof(*out));
    if (private_data->emitted) {
        out->release = NULL;
        return NANOARROW_OK;
    }
    if (!private_data->array || !private_data->array->release) {
        snprintf(private_data->error, sizeof(private_data->error), "borrowed Arrow stream array is invalid");
        return EINVAL;
    }
    memcpy(out, private_data->array, sizeof(*out));
    out->release = rducks_borrowed_array_release;
    private_data->emitted = 1;
    return NANOARROW_OK;
}

static const char *rducks_borrowed_array_stream_get_last_error(struct ArrowArrayStream *stream) {
    rducks_borrowed_array_stream_private_t *private_data;
    if (!stream || !stream->private_data) return NULL;
    private_data = (rducks_borrowed_array_stream_private_t *)stream->private_data;
    return private_data->error[0] ? private_data->error : NULL;
}

static void rducks_borrowed_array_stream_release(struct ArrowArrayStream *stream) {
    if (!stream) return;
    free(stream->private_data);
    stream->private_data = NULL;
    stream->release = NULL;
}

static int rducks_borrowed_array_stream_init(struct ArrowArrayStream *stream,
                                             const struct ArrowSchema *schema,
                                             const struct ArrowArray *array,
                                             char *err_msg, size_t err_cap) {
    rducks_borrowed_array_stream_private_t *private_data;
    if (!stream || !schema || !array) return 0;
    memset(stream, 0, sizeof(*stream));
    private_data = (rducks_borrowed_array_stream_private_t *)calloc(1, sizeof(*private_data));
    if (!private_data) {
        snprintf(err_msg, err_cap, "out of memory allocating Arrow IPC stream state");
        return 0;
    }
    private_data->schema = schema;
    private_data->array = array;
    stream->get_schema = rducks_borrowed_array_stream_get_schema;
    stream->get_next = rducks_borrowed_array_stream_get_next;
    stream->get_last_error = rducks_borrowed_array_stream_get_last_error;
    stream->release = rducks_borrowed_array_stream_release;
    stream->private_data = private_data;
    return 1;
}

static int rducks_arrow_ipc_encode_borrowed_array(const struct ArrowSchema *schema,
                                                  const struct ArrowArray *array,
                                                  uint8_t **bytes_out,
                                                  size_t *size_out,
                                                  char *err_msg, size_t err_cap) {
    struct ArrowArrayStream array_stream;
    struct ArrowBuffer buffer;
    struct ArrowIpcOutputStream output_stream;
    struct ArrowIpcWriter writer;
    struct ArrowError error;
    int stream_initialized = 0;
    int output_initialized = 0;
    int writer_initialized = 0;
    int ok = 0;

    if (!bytes_out || !size_out) return 0;
    *bytes_out = NULL;
    *size_out = 0;
    memset(&array_stream, 0, sizeof(array_stream));
    memset(&output_stream, 0, sizeof(output_stream));
    memset(&writer, 0, sizeof(writer));
    memset(&error, 0, sizeof(error));
    ArrowBufferInit(&buffer);

    if (!schema || !schema->release || !array || !array->release) {
        snprintf(err_msg, err_cap, "invalid Arrow C Data input for IPC encoding");
        goto cleanup;
    }
    if (!rducks_borrowed_array_stream_init(&array_stream, schema, array, err_msg, err_cap)) goto cleanup;
    stream_initialized = 1;

    if (ArrowIpcOutputStreamInitBuffer(&output_stream, &buffer) != NANOARROW_OK) {
        snprintf(err_msg, err_cap, "ArrowIpcOutputStreamInitBuffer() failed");
        goto cleanup;
    }
    output_initialized = 1;
    if (ArrowIpcWriterInit(&writer, &output_stream) != NANOARROW_OK) {
        snprintf(err_msg, err_cap, "ArrowIpcWriterInit() failed");
        goto cleanup;
    }
    output_initialized = 0;
    writer_initialized = 1;
    if (ArrowIpcWriterWriteArrayStream(&writer, &array_stream, &error) != NANOARROW_OK) {
        snprintf(err_msg, err_cap, "Arrow IPC stream write failed: %s", error.message[0] ? error.message : "unknown error");
        goto cleanup;
    }
    if (buffer.size_bytes < 0 || (uint64_t)buffer.size_bytes > (uint64_t)SIZE_MAX) {
        snprintf(err_msg, err_cap, "Arrow IPC payload is too large");
        goto cleanup;
    }
    *bytes_out = buffer.data;
    *size_out = (size_t)buffer.size_bytes;
    buffer.data = NULL;
    buffer.size_bytes = 0;
    buffer.capacity_bytes = 0;
    ok = 1;

cleanup:
    if (writer_initialized) ArrowIpcWriterReset(&writer);
    if (output_initialized && output_stream.release) output_stream.release(&output_stream);
    if (stream_initialized && array_stream.release) array_stream.release(&array_stream);
    ArrowBufferReset(&buffer);
    return ok;
}

#endif
