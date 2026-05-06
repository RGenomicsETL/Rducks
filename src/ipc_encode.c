#ifndef R_NO_REMAP
#define R_NO_REMAP
#endif
#include <R.h>
#include <Rinternals.h>

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#include <nanoarrow/r.h>

#define RDUCKS_NANOARROW_OK 0

typedef int ArrowErrorCode;

struct ArrowError {
    char message[1024];
};

struct ArrowBufferAllocator {
    uint8_t *(*reallocate)(struct ArrowBufferAllocator *allocator, uint8_t *ptr,
                           int64_t old_size, int64_t new_size);
    void (*free)(struct ArrowBufferAllocator *allocator, uint8_t *ptr, int64_t size);
    void *private_data;
};

struct ArrowBuffer {
    uint8_t *data;
    int64_t size_bytes;
    int64_t capacity_bytes;
    struct ArrowBufferAllocator allocator;
};

struct ArrowIpcOutputStream {
    ArrowErrorCode (*write)(struct ArrowIpcOutputStream *stream, const void *buf,
                            int64_t buf_size_bytes, int64_t *size_written_out,
                            struct ArrowError *error);
    void (*release)(struct ArrowIpcOutputStream *stream);
    void *private_data;
};

struct ArrowIpcWriter {
    void *private_data;
};

typedef ArrowErrorCode (*rducks_arrow_ipc_output_stream_init_buffer_fn)(
    struct ArrowIpcOutputStream *stream, struct ArrowBuffer *output);
typedef ArrowErrorCode (*rducks_arrow_ipc_writer_init_fn)(
    struct ArrowIpcWriter *writer, struct ArrowIpcOutputStream *output_stream);
typedef void (*rducks_arrow_ipc_writer_reset_fn)(struct ArrowIpcWriter *writer);
typedef ArrowErrorCode (*rducks_arrow_ipc_writer_write_array_stream_fn)(
    struct ArrowIpcWriter *writer, struct ArrowArrayStream *in, struct ArrowError *error);

typedef struct rducks_nanoarrow_ipc_symbols {
    rducks_arrow_ipc_output_stream_init_buffer_fn output_stream_init_buffer;
    rducks_arrow_ipc_writer_init_fn writer_init;
    rducks_arrow_ipc_writer_reset_fn writer_reset;
    rducks_arrow_ipc_writer_write_array_stream_fn writer_write_array_stream;
} rducks_nanoarrow_ipc_symbols_t;

static uint8_t *rducks_arrow_buffer_reallocate(struct ArrowBufferAllocator *allocator,
                                               uint8_t *ptr, int64_t old_size,
                                               int64_t new_size) {
    (void)allocator;
    (void)old_size;
    if (new_size <= 0) {
        free(ptr);
        return NULL;
    }
    return (uint8_t *)realloc(ptr, (size_t)new_size);
}

static void rducks_arrow_buffer_free(struct ArrowBufferAllocator *allocator,
                                     uint8_t *ptr, int64_t size) {
    (void)allocator;
    (void)size;
    free(ptr);
}

static void *rducks_dynamic_library_symbol(const char *path, const char *name) {
#ifdef _WIN32
    static HMODULE handle = NULL;
    void *ptr;
    if (!handle) {
        handle = LoadLibraryA(path);
        if (!handle) Rf_error("failed to load nanoarrow DLL: %s", path);
    }
    ptr = (void *)GetProcAddress(handle, name);
#else
    static void *handle = NULL;
    void *ptr;
    if (!handle) {
        handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
        if (!handle) Rf_error("failed to load nanoarrow shared library: %s", dlerror());
    }
    ptr = dlsym(handle, name);
#endif
    if (!ptr) Rf_error("nanoarrow native symbol not available: %s", name);
    return ptr;
}

static void rducks_load_nanoarrow_ipc_symbols(SEXP nanoarrow_dll_path_sexp,
                                              rducks_nanoarrow_ipc_symbols_t *symbols) {
    const char *path;
    if (!Rf_isString(nanoarrow_dll_path_sexp) || XLENGTH(nanoarrow_dll_path_sexp) != 1 ||
        STRING_ELT(nanoarrow_dll_path_sexp, 0) == NA_STRING) {
        Rf_error("nanoarrow_dll_path must be a character scalar");
    }
    path = CHAR(STRING_ELT(nanoarrow_dll_path_sexp, 0));
    symbols->output_stream_init_buffer =
        (rducks_arrow_ipc_output_stream_init_buffer_fn)rducks_dynamic_library_symbol(path, "RPkgArrowIpcOutputStreamInitBuffer");
    symbols->writer_init =
        (rducks_arrow_ipc_writer_init_fn)rducks_dynamic_library_symbol(path, "RPkgArrowIpcWriterInit");
    symbols->writer_reset =
        (rducks_arrow_ipc_writer_reset_fn)rducks_dynamic_library_symbol(path, "RPkgArrowIpcWriterReset");
    symbols->writer_write_array_stream =
        (rducks_arrow_ipc_writer_write_array_stream_fn)rducks_dynamic_library_symbol(path, "RPkgArrowIpcWriterWriteArrayStream");
}

static void rducks_arrow_buffer_init(struct ArrowBuffer *buffer) {
    memset(buffer, 0, sizeof(*buffer));
    buffer->allocator.reallocate = rducks_arrow_buffer_reallocate;
    buffer->allocator.free = rducks_arrow_buffer_free;
    buffer->allocator.private_data = NULL;
}

static void rducks_arrow_buffer_reset(struct ArrowBuffer *buffer) {
    if (!buffer) return;
    if (buffer->data && buffer->allocator.free) {
        buffer->allocator.free(&buffer->allocator, buffer->data, buffer->capacity_bytes);
    }
    memset(buffer, 0, sizeof(*buffer));
}

static void rducks_arrow_error_init(struct ArrowError *error) {
    if (error) error->message[0] = '\0';
}

typedef struct rducks_single_array_stream_data {
    SEXP array_xptr;
    SEXP schema_xptr;
    int delivered;
    char error[256];
} rducks_single_array_stream_data_t;

static void rducks_noop_schema_release(struct ArrowSchema *schema) {
    if (schema) schema->release = NULL;
}

static void rducks_noop_array_release(struct ArrowArray *array) {
    if (array) array->release = NULL;
}

static int rducks_single_array_stream_get_schema(struct ArrowArrayStream *stream,
                                                 struct ArrowSchema *out) {
    rducks_single_array_stream_data_t *data;
    struct ArrowSchema *schema;
    if (!stream || !out || !stream->private_data) return EINVAL;
    data = (rducks_single_array_stream_data_t *)stream->private_data;
    schema = nanoarrow_schema_from_xptr(data->schema_xptr);
    memcpy(out, schema, sizeof(*out));
    out->release = rducks_noop_schema_release;
    return 0;
}

static int rducks_single_array_stream_get_next(struct ArrowArrayStream *stream,
                                               struct ArrowArray *out) {
    rducks_single_array_stream_data_t *data;
    struct ArrowArray *array;
    if (!stream || !out || !stream->private_data) return EINVAL;
    data = (rducks_single_array_stream_data_t *)stream->private_data;
    if (data->delivered) {
        memset(out, 0, sizeof(*out));
        out->release = NULL;
        return 0;
    }
    array = nanoarrow_array_from_xptr(data->array_xptr);
    memcpy(out, array, sizeof(*out));
    out->release = rducks_noop_array_release;
    data->delivered = 1;
    return 0;
}

static const char *rducks_single_array_stream_get_last_error(struct ArrowArrayStream *stream) {
    rducks_single_array_stream_data_t *data;
    if (!stream || !stream->private_data) return "Rducks Arrow IPC array stream is missing state";
    data = (rducks_single_array_stream_data_t *)stream->private_data;
    return data->error;
}

static void rducks_single_array_stream_release(struct ArrowArrayStream *stream) {
    rducks_single_array_stream_data_t *data;
    if (!stream || !stream->release) return;
    data = (rducks_single_array_stream_data_t *)stream->private_data;
    if (data) {
        if (data->array_xptr != R_NilValue) R_ReleaseObject(data->array_xptr);
        if (data->schema_xptr != R_NilValue) R_ReleaseObject(data->schema_xptr);
        free(data);
    }
    stream->private_data = NULL;
    stream->release = NULL;
}

static void rducks_single_array_stream_init(struct ArrowArrayStream *stream,
                                            SEXP array_xptr, SEXP schema_xptr) {
    rducks_single_array_stream_data_t *data =
        (rducks_single_array_stream_data_t *)calloc(1, sizeof(*data));
    if (!data) Rf_error("out of memory allocating Rducks Arrow IPC stream state");
    data->array_xptr = array_xptr;
    data->schema_xptr = schema_xptr;
    data->delivered = 0;
    data->error[0] = '\0';
    R_PreserveObject(array_xptr);
    R_PreserveObject(schema_xptr);

    memset(stream, 0, sizeof(*stream));
    stream->get_schema = rducks_single_array_stream_get_schema;
    stream->get_next = rducks_single_array_stream_get_next;
    stream->get_last_error = rducks_single_array_stream_get_last_error;
    stream->release = rducks_single_array_stream_release;
    stream->private_data = data;
}

typedef struct rducks_ipc_encode_cleanup {
    struct ArrowBuffer *buffer;
    struct ArrowArrayStream *array_stream;
    struct ArrowIpcWriter *writer;
    rducks_arrow_ipc_writer_reset_fn writer_reset;
    int writer_initialized;
    int cleaned;
} rducks_ipc_encode_cleanup_t;

static void rducks_ipc_encode_cleanup(void *data, Rboolean jump) {
    (void)jump;
    rducks_ipc_encode_cleanup_t *cleanup = (rducks_ipc_encode_cleanup_t *)data;
    if (!cleanup || cleanup->cleaned) return;
    if (cleanup->writer_initialized && cleanup->writer_reset && cleanup->writer) {
        cleanup->writer_reset(cleanup->writer);
        cleanup->writer_initialized = 0;
    }
    if (cleanup->array_stream && cleanup->array_stream->release) {
        cleanup->array_stream->release(cleanup->array_stream);
    }
    if (cleanup->buffer) {
        rducks_arrow_buffer_reset(cleanup->buffer);
    }
    cleanup->cleaned = 1;
}

static SEXP rducks_ipc_encode_alloc_raw(void *data) {
    rducks_ipc_encode_cleanup_t *cleanup = (rducks_ipc_encode_cleanup_t *)data;
    struct ArrowBuffer *buffer = cleanup->buffer;
    SEXP out = Rf_allocVector(RAWSXP, (R_xlen_t)buffer->size_bytes);
    if (buffer->size_bytes > 0) {
        memcpy(RAW(out), buffer->data, (size_t)buffer->size_bytes);
    }
    return out;
}

SEXP RDUCKS_arrow_ipc_encode_array(SEXP array_xptr, SEXP nanoarrow_dll_path_sexp) {
    SEXP schema_xptr = R_NilValue;
    struct ArrowBuffer buffer;
    struct ArrowIpcOutputStream output_stream;
    struct ArrowIpcWriter writer;
    struct ArrowArrayStream array_stream;
    struct ArrowError error;
    rducks_ipc_encode_cleanup_t cleanup;
    rducks_nanoarrow_ipc_symbols_t symbols;

    memset(&symbols, 0, sizeof(symbols));
    rducks_load_nanoarrow_ipc_symbols(nanoarrow_dll_path_sexp, &symbols);

    if (!Rf_inherits(array_xptr, "nanoarrow_array")) {
        Rf_error("array_xptr must be a nanoarrow_array external pointer");
    }
    schema_xptr = R_ExternalPtrTag(array_xptr);
    if (schema_xptr == R_NilValue || !Rf_inherits(schema_xptr, "nanoarrow_schema")) {
        Rf_error("nanoarrow_array does not carry a nanoarrow_schema tag");
    }
    (void)nanoarrow_array_from_xptr(array_xptr);
    (void)nanoarrow_schema_from_xptr(schema_xptr);

    rducks_arrow_buffer_init(&buffer);
    memset(&output_stream, 0, sizeof(output_stream));
    memset(&writer, 0, sizeof(writer));
    memset(&array_stream, 0, sizeof(array_stream));
    rducks_arrow_error_init(&error);
    memset(&cleanup, 0, sizeof(cleanup));
    cleanup.buffer = &buffer;
    cleanup.array_stream = &array_stream;
    cleanup.writer = &writer;
    cleanup.writer_reset = symbols.writer_reset;

    rducks_single_array_stream_init(&array_stream, array_xptr, schema_xptr);

    if (symbols.output_stream_init_buffer(&output_stream, &buffer) != RDUCKS_NANOARROW_OK) {
        rducks_ipc_encode_cleanup(&cleanup, FALSE);
        Rf_error("ArrowIpcOutputStreamInitBuffer() failed");
    }
    if (symbols.writer_init(&writer, &output_stream) != RDUCKS_NANOARROW_OK) {
        rducks_ipc_encode_cleanup(&cleanup, FALSE);
        Rf_error("ArrowIpcWriterInit() failed");
    }
    cleanup.writer_initialized = 1;

    if (symbols.writer_write_array_stream(&writer, &array_stream, &error) != RDUCKS_NANOARROW_OK) {
        rducks_ipc_encode_cleanup(&cleanup, FALSE);
        Rf_error("ArrowIpcWriterWriteArrayStream() failed: %s", error.message[0] ? error.message : "unknown error");
    }

    return R_UnwindProtect(rducks_ipc_encode_alloc_raw, &cleanup,
                           rducks_ipc_encode_cleanup, &cleanup,
                           NULL);
}
