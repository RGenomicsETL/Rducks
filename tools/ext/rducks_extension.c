/* Rducks DuckDB extension
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#ifndef R_NO_REMAP
#define R_NO_REMAP
#endif
#include "duckdb_extension.h"

/* DuckDB exposed GEOMETRY and VARIANT in the C API after early 1.5 headers.
 * Keep their numeric ids isolated here so each exact-version build compiles
 * against its matching header while still recognizing the runtime type ids.
 * Do not use cast duckdb_type values in switch labels: older headers define
 * duckdb_type as an enum without values 40/41, and CRAN/CI compilers warn on
 * such case labels.
 */
#define RDUCKS_DUCKDB_TYPE_GEOMETRY_ID 40
#define RDUCKS_DUCKDB_TYPE_GEOMETRY ((duckdb_type)RDUCKS_DUCKDB_TYPE_GEOMETRY_ID)
#define RDUCKS_DUCKDB_TYPE_VARIANT_ID 41
#define RDUCKS_DUCKDB_TYPE_VARIANT ((duckdb_type)RDUCKS_DUCKDB_TYPE_VARIANT_ID)

/* VARIANT support is runtime-gated. duckdb_create_logical_type(41) creates an
 * id-only type without DuckDB's physical child metadata, so Rducks obtains a
 * canonical type from `SELECT NULL::VARIANT`, validates its complete
 * STRUCT(keys, children, values, data) layout through generic C APIs, and only
 * then enables direct and IPC marshalling. Older or layout-incompatible
 * runtimes remain fail-closed. */

#if !defined(DUCKDB_EXTENSION_API_VERSION_UNSTABLE) || !defined(DUCKDB_EXTENSION_API_UNSTABLE_VERSION)
#error "Rducks requires DuckDB's unstable C extension API; build with USE_UNSTABLE_C_API=1"
#endif

#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wpedantic"
#endif
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Arith.h>
#include <R_ext/Utils.h>
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif

#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#include <time.h>
#endif

DUCKDB_EXTENSION_EXTERN

#define RDUCKS_ERROR_BUFFER_SIZE 1024U

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
    RDUCKS_TYPE_GEOMETRY,
    RDUCKS_TYPE_VARIANT,
    RDUCKS_TYPE_DATE,
    RDUCKS_TYPE_TIME,
    RDUCKS_TYPE_TIMESTAMP,
    RDUCKS_TYPE_HUGEINT,
    RDUCKS_TYPE_UHUGEINT,
    RDUCKS_TYPE_UUID,
    RDUCKS_TYPE_INTERVAL,
    RDUCKS_TYPE_BIT
} rducks_type_id_t;

typedef enum rducks_null_handling {
    RDUCKS_NULL_DEFAULT = 0,
    RDUCKS_NULL_SPECIAL = 1
} rducks_null_handling_t;

typedef enum rducks_exception_handling {
    RDUCKS_EXCEPTION_RETHROW = 0,
    RDUCKS_EXCEPTION_RETURN_NULL = 1
} rducks_exception_handling_t;

typedef enum rducks_eval_mode {
    RDUCKS_EVAL_R = 0,
    RDUCKS_EVAL_RC = 1,
    RDUCKS_EVAL_RCV = 2,
    RDUCKS_EVAL_RIPC = 3
} rducks_eval_mode_t;

typedef enum rducks_execution_backend {
    RDUCKS_BACKEND_SINGLE = 0,
    RDUCKS_BACKEND_CONCURRENT_INPROC = 1,
    RDUCKS_BACKEND_MULTIPROCESS_PARALLEL = 2
} rducks_execution_backend_t;

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

typedef struct rducks_udf_request rducks_udf_request_t;
typedef struct rducks_r_scalar_meta rducks_r_scalar_meta_t;
typedef struct rducks_nng_client_pool rducks_nng_client_pool_t;
typedef struct rducks_query_stream_entry rducks_query_stream_entry_t;

typedef struct rducks_type_desc {
    rducks_type_kind_t kind;
    rducks_type_id_t scalar;
    struct rducks_type_desc *child;
    struct rducks_type_desc *key;
    struct rducks_type_desc *value;
    idx_t array_size;
    uint8_t decimal_width;
    uint8_t decimal_scale;
    duckdb_type enum_internal_type;
    size_t field_count;
    char **field_names;
    struct rducks_type_desc **field_types;
    uint32_t *field_hash_heads;
    uint32_t *field_hash_next;
    size_t field_hash_bucket_count;
} rducks_type_desc_t;

typedef struct rducks_runtime_entry {
    duckdb_database database;
    duckdb_connection connection;
    duckdb_connection query_stream_connection;
    int query_stream_connection_busy;
    /* Canonical VARIANT type obtained from the runtime SQL binder. Unlike
     * duckdb_create_logical_type(41), this carries DuckDB's required physical
     * STRUCT children. A NULL handle means this runtime failed the dynamic
     * layout probe and every VARIANT registration must remain rejected. */
    duckdb_logical_type variant_logical_type;
    uint64_t runtime_id;
    uint64_t generation;
    int registration_surface_ready;
    char main_thread_token[128];
    int main_thread_token_set;
#ifdef _WIN32
    DWORD main_thread_id;
#else
    const pthread_t *main_thread_id;
#endif
    rducks_execution_backend_t execution_backend;
    rducks_udf_request_t *queue_head;
    rducks_udf_request_t *queue_tail;
    uint64_t queue_submitted;
    uint64_t queue_executed;
    uint64_t queue_timeouts;
    uint64_t queue_pending_current;
    uint64_t queue_pending_max;
    uint64_t queue_running_current;
    uint64_t queue_running_max;
    uint64_t queue_main_drains;
    uint64_t queue_main_drain_batches;
    uint64_t queue_main_drain_max_batch;
    atomic_uint_fast64_t queue_cancel_generation;
    atomic_uint_fast64_t queue_interrupt_checks;
    atomic_uint_fast64_t queue_interrupts;
    rducks_r_scalar_meta_t *udf_registry_head;
    rducks_r_scalar_meta_t **udf_registry_buckets;
    size_t udf_registry_bucket_count;
    size_t udf_registry_size;
#ifdef _WIN32
    CRITICAL_SECTION queue_lock;
    CONDITION_VARIABLE queue_cond;
#else
    pthread_mutex_t queue_lock;
    pthread_cond_t queue_cond;
#endif
    int queue_initialized;
    rducks_query_stream_entry_t *query_streams;
    uint64_t query_stream_next_id;
} rducks_runtime_entry_t;

struct rducks_r_scalar_meta {
    SEXP fun;
    char *name;
    rducks_r_scalar_meta_t *registry_next;
    rducks_r_scalar_meta_t *registry_hash_next;
    size_t arity;
    struct rducks_type_desc **args;
    int dynamic_args;
    struct rducks_type_desc *return_desc;
    rducks_null_handling_t null_handling;
    rducks_exception_handling_t exception_handling;
    rducks_eval_mode_t eval_mode;
    rducks_runtime_entry_t *runtime;
    char **ripc_endpoints;
    size_t ripc_endpoint_count;
    char *ripc_udf_id;
    int ripc_timeout_ms;
    uint64_t ripc_max_pending;
    int ripc_external_endpoints;
    rducks_nng_client_pool_t *ripc_client_pool;
    atomic_uint_fast64_t ripc_next_endpoint;
    atomic_uint_fast64_t dispatch_chunks;
    atomic_uint_fast64_t dispatch_rows;
    atomic_uint_fast64_t direct_chunks;
    atomic_uint_fast64_t queued_chunks;
    atomic_uint_fast64_t queue_pending_current;
    atomic_uint_fast64_t queue_pending_max;
    atomic_uint_fast64_t sexp_chunks;
    atomic_uint_fast64_t direct_eval_chunks;
    atomic_uint_fast64_t direct_input_snapshot_chunks;
    atomic_uint_fast64_t direct_owned_result_chunk_chunks;
    atomic_uint_fast64_t wire_chunks;
    atomic_uint_fast64_t ripc_collect_batches;
    atomic_uint_fast64_t ripc_collect_requests;
    atomic_uint_fast64_t ripc_collect_max_batch;
    atomic_uint_fast64_t ripc_submit_wave_max;
    atomic_uint_fast64_t ripc_collect_ready_max;
    atomic_uint_fast64_t ripc_inflight_current;
    atomic_uint_fast64_t ripc_inflight_max;
};

typedef struct rducks_r_scalar_bind_state {
    rducks_runtime_entry_t *runtime;
    size_t arity;
    rducks_type_desc_t **args;
} rducks_r_scalar_bind_state_t;

typedef struct rducks_r_scalar_local_state {
    rducks_runtime_entry_t *runtime;
    size_t arity;
    rducks_type_desc_t **args;
} rducks_r_scalar_local_state_t;

static rducks_runtime_entry_t **g_runtime_entries = NULL;
static idx_t g_runtime_count = 0;
static idx_t g_runtime_capacity = 0;
/* Process-local runtime ids avoid using raw duckdb_database pointer values as
 * R-side keys. They are intentionally not durable across R sessions.
 */
static uint64_t g_runtime_next_process_id = 1;
static uint64_t g_runtime_entries_created = 0;
static uint64_t g_runtime_stale_aliases = 0;
static uint64_t g_runtime_connections_opened = 0;
static uint64_t g_runtime_connections_closed = 0;
static uint64_t g_runtime_connection_open_failed = 0;
static uint64_t g_runtime_queue_init_failed = 0;

static int rducks_size_mul(size_t a, size_t b, size_t *out) {
    if (!out) return 0;
    if (b != 0 && a > SIZE_MAX / b) return 0;
    *out = a * b;
    return 1;
}

static void *rducks_calloc_array(size_t n, size_t size) {
    size_t bytes;
    if (!rducks_size_mul(n, size, &bytes)) return NULL;
    return calloc(n, size);
}

static void *rducks_realloc_array(void *ptr, size_t n, size_t size) {
    size_t bytes;
    if (!rducks_size_mul(n, size, &bytes)) return NULL;
    return realloc(ptr, bytes);
}

static void rducks_copy_error_message(char *out, size_t out_cap,
                                      const char *message, const char *fallback);

/* Locking discipline: avoid nesting the global runtime registry lock and a
 * runtime queue lock. Queue operations should release runtime->queue_lock before
 * updating registry/stat counters under g_runtime_lock. If future code must
 * nest these locks, re-audit every caller and document one global order here.
 */
#ifdef _WIN32
static CRITICAL_SECTION g_runtime_lock;
static CRITICAL_SECTION g_registration_lock;
static INIT_ONCE g_runtime_lock_once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK rducks_runtime_lock_init_once(PINIT_ONCE once, PVOID param, PVOID *context) {
    (void)once;
    (void)param;
    (void)context;
    InitializeCriticalSection(&g_runtime_lock);
    InitializeCriticalSection(&g_registration_lock);
    return TRUE;
}
static void rducks_runtime_lock(void) {
    InitOnceExecuteOnce(&g_runtime_lock_once, rducks_runtime_lock_init_once, NULL, NULL);
    EnterCriticalSection(&g_runtime_lock);
}
static int rducks_runtime_try_lock(void) {
    InitOnceExecuteOnce(&g_runtime_lock_once, rducks_runtime_lock_init_once, NULL, NULL);
    return TryEnterCriticalSection(&g_runtime_lock) ? 1 : 0;
}
static void rducks_runtime_unlock(void) { LeaveCriticalSection(&g_runtime_lock); }
static void rducks_registration_lock(void) {
    InitOnceExecuteOnce(&g_runtime_lock_once, rducks_runtime_lock_init_once, NULL, NULL);
    EnterCriticalSection(&g_registration_lock);
}
static void rducks_registration_unlock(void) { LeaveCriticalSection(&g_registration_lock); }
#else
static pthread_mutex_t g_runtime_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_registration_lock = PTHREAD_MUTEX_INITIALIZER;
static void rducks_runtime_lock(void) { pthread_mutex_lock(&g_runtime_lock); }
static int rducks_runtime_try_lock(void) { return pthread_mutex_trylock(&g_runtime_lock) == 0 ? 1 : 0; }
static void rducks_runtime_unlock(void) { pthread_mutex_unlock(&g_runtime_lock); }
static void rducks_registration_lock(void) { pthread_mutex_lock(&g_registration_lock); }
static void rducks_registration_unlock(void) { pthread_mutex_unlock(&g_registration_lock); }
#endif

static rducks_runtime_entry_t *rducks_runtime_find_locked(duckdb_database database) {
    for (idx_t i = 0; i < g_runtime_count; i++) {
        if (g_runtime_entries[i] && g_runtime_entries[i]->database == database) return g_runtime_entries[i];
    }
    return NULL;
}

static int rducks_registration_surface_available(duckdb_connection connection) {
    duckdb_prepared_statement stmt = NULL;
    duckdb_state rc;
    if (!connection) return 0;
    rc = duckdb_prepare(connection, "SELECT rducks_version()", &stmt);
    if (stmt) duckdb_destroy_prepare(&stmt);
    return rc == DuckDBSuccess;
}

static int rducks_runtime_reserve_locked(idx_t wanted) {
    rducks_runtime_entry_t **new_entries;
    idx_t new_capacity;
    size_t bytes;
    if (g_runtime_capacity >= wanted) return 1;
    new_capacity = g_runtime_capacity == 0 ? 4 : g_runtime_capacity;
    while (new_capacity < wanted) {
        if (new_capacity > (idx_t)(SIZE_MAX / (2U * sizeof(*new_entries)))) return 0;
        new_capacity *= 2;
    }
    if ((uint64_t)new_capacity > (uint64_t)(SIZE_MAX / sizeof(*new_entries))) return 0;
    if (!rducks_size_mul((size_t)new_capacity, sizeof(*new_entries), &bytes)) return 0;
    new_entries = (rducks_runtime_entry_t **)duckdb_malloc(bytes);
    if (!new_entries) return 0;
    memset(new_entries, 0, bytes);
    if (g_runtime_entries && g_runtime_count > 0) {
        memcpy(new_entries, g_runtime_entries, sizeof(*new_entries) * (size_t)g_runtime_count);
        duckdb_free(g_runtime_entries);
    }
    g_runtime_entries = new_entries;
    g_runtime_capacity = new_capacity;
    return 1;
}

static int rducks_runtime_queue_init_entry(rducks_runtime_entry_t *entry) {
    if (!entry) return 0;
    atomic_init(&entry->queue_cancel_generation, 0U);
    atomic_init(&entry->queue_interrupt_checks, 0U);
    atomic_init(&entry->queue_interrupts, 0U);
#ifdef _WIN32
    InitializeCriticalSection(&entry->queue_lock);
    InitializeConditionVariable(&entry->queue_cond);
    entry->queue_initialized = 1;
    return 1;
#else
    if (pthread_mutex_init(&entry->queue_lock, NULL) != 0) return 0;
    if (pthread_cond_init(&entry->queue_cond, NULL) != 0) {
        pthread_mutex_destroy(&entry->queue_lock);
        return 0;
    }
    entry->queue_initialized = 1;
    return 1;
#endif
}

static void rducks_runtime_queue_destroy_entry(rducks_runtime_entry_t *entry) {
    if (!entry || !entry->queue_initialized) return;
#ifdef _WIN32
    DeleteCriticalSection(&entry->queue_lock);
#else
    pthread_cond_destroy(&entry->queue_cond);
    pthread_mutex_destroy(&entry->queue_lock);
#endif
    entry->queue_initialized = 0;
}

static int rducks_runtime_configure_connection(duckdb_connection connection, char *err, size_t err_cap) {
    /* Hook for extension-owned connection setup. Direct DuckDB-vector
     * marshalling needs no DuckDB session settings. */
    if (!connection) {
        snprintf(err, err_cap, "Rducks runtime connection is missing");
        return 0;
    }
    return 1;
}

static int rducks_variant_struct_child_matches(duckdb_logical_type type, idx_t index,
                                                const char *name, duckdb_type expected_type) {
    duckdb_logical_type child = NULL;
    char *child_name = NULL;
    int ok = 0;
    if (!type || duckdb_struct_type_child_count(type) <= index) return 0;
    child_name = duckdb_struct_type_child_name(type, index);
    child = duckdb_struct_type_child_type(type, index);
    ok = child_name && name && strcmp(child_name, name) == 0 && child &&
         duckdb_get_type_id(child) == expected_type;
    if (child_name) duckdb_free(child_name);
    if (child) duckdb_destroy_logical_type(&child);
    return ok;
}

static int rducks_variant_list_struct_matches(duckdb_logical_type list_type,
                                               const char *first_name, duckdb_type first_type,
                                               const char *second_name, duckdb_type second_type) {
    duckdb_logical_type child = NULL;
    int ok = 0;
    if (!list_type || duckdb_get_type_id(list_type) != DUCKDB_TYPE_LIST) return 0;
    child = duckdb_list_type_child_type(list_type);
    if (!child) return 0;
    ok = duckdb_get_type_id(child) == DUCKDB_TYPE_STRUCT &&
         duckdb_struct_type_child_count(child) == 2 &&
         rducks_variant_struct_child_matches(child, 0, first_name, first_type) &&
         rducks_variant_struct_child_matches(child, 1, second_name, second_type);
    duckdb_destroy_logical_type(&child);
    return ok;
}

static int rducks_variant_logical_type_has_expected_layout(duckdb_logical_type type) {
    duckdb_logical_type keys = NULL;
    duckdb_logical_type children = NULL;
    duckdb_logical_type values = NULL;
    duckdb_logical_type keys_child = NULL;
    int ok = 0;
    if (!type || (int)duckdb_get_type_id(type) != RDUCKS_DUCKDB_TYPE_VARIANT_ID ||
        duckdb_struct_type_child_count(type) != 4) {
        return 0;
    }
    if (!rducks_variant_struct_child_matches(type, 0, "keys", DUCKDB_TYPE_LIST) ||
        !rducks_variant_struct_child_matches(type, 1, "children", DUCKDB_TYPE_LIST) ||
        !rducks_variant_struct_child_matches(type, 2, "values", DUCKDB_TYPE_LIST) ||
        !rducks_variant_struct_child_matches(type, 3, "data", DUCKDB_TYPE_BLOB)) {
        return 0;
    }
    keys = duckdb_struct_type_child_type(type, 0);
    children = duckdb_struct_type_child_type(type, 1);
    values = duckdb_struct_type_child_type(type, 2);
    if (!keys || !children || !values) goto cleanup;
    keys_child = duckdb_list_type_child_type(keys);
    if (!keys_child || duckdb_get_type_id(keys_child) != DUCKDB_TYPE_VARCHAR) goto cleanup;
    if (!rducks_variant_list_struct_matches(children, "keys_index", DUCKDB_TYPE_UINTEGER,
                                             "values_index", DUCKDB_TYPE_UINTEGER)) goto cleanup;
    if (!rducks_variant_list_struct_matches(values, "type_id", DUCKDB_TYPE_UTINYINT,
                                             "byte_offset", DUCKDB_TYPE_UINTEGER)) goto cleanup;
    ok = 1;
cleanup:
    if (keys_child) duckdb_destroy_logical_type(&keys_child);
    if (keys) duckdb_destroy_logical_type(&keys);
    if (children) duckdb_destroy_logical_type(&children);
    if (values) duckdb_destroy_logical_type(&values);
    return ok;
}

static int rducks_vector_has_type(duckdb_vector vector, duckdb_type expected_type) {
    duckdb_logical_type type = NULL;
    int ok = 0;
    if (!vector) return 0;
    type = duckdb_vector_get_column_type(vector);
    ok = type && duckdb_get_type_id(type) == expected_type;
    if (type) duckdb_destroy_logical_type(&type);
    return ok;
}

static int rducks_variant_vector_has_expected_layout(duckdb_vector vector) {
    duckdb_vector keys;
    duckdb_vector children;
    duckdb_vector values;
    duckdb_vector data;
    duckdb_vector keys_entry;
    duckdb_vector children_entry;
    duckdb_vector values_entry;
    if (!vector) return 0;
    keys = duckdb_struct_vector_get_child(vector, 0);
    children = duckdb_struct_vector_get_child(vector, 1);
    values = duckdb_struct_vector_get_child(vector, 2);
    data = duckdb_struct_vector_get_child(vector, 3);
    if (!rducks_vector_has_type(keys, DUCKDB_TYPE_LIST) ||
        !rducks_vector_has_type(children, DUCKDB_TYPE_LIST) ||
        !rducks_vector_has_type(values, DUCKDB_TYPE_LIST) ||
        !rducks_vector_has_type(data, DUCKDB_TYPE_BLOB)) return 0;
    keys_entry = duckdb_list_vector_get_child(keys);
    children_entry = duckdb_list_vector_get_child(children);
    values_entry = duckdb_list_vector_get_child(values);
    if (!rducks_vector_has_type(keys_entry, DUCKDB_TYPE_VARCHAR) ||
        !rducks_vector_has_type(children_entry, DUCKDB_TYPE_STRUCT) ||
        !rducks_vector_has_type(values_entry, DUCKDB_TYPE_STRUCT)) return 0;
    if (!rducks_vector_has_type(duckdb_struct_vector_get_child(children_entry, 0), DUCKDB_TYPE_UINTEGER) ||
        !rducks_vector_has_type(duckdb_struct_vector_get_child(children_entry, 1), DUCKDB_TYPE_UINTEGER) ||
        !rducks_vector_has_type(duckdb_struct_vector_get_child(values_entry, 0), DUCKDB_TYPE_UTINYINT) ||
        !rducks_vector_has_type(duckdb_struct_vector_get_child(values_entry, 1), DUCKDB_TYPE_UINTEGER)) return 0;
    return 1;
}

static duckdb_logical_type rducks_probe_variant_logical_type(duckdb_connection connection) {
    duckdb_result result;
    duckdb_logical_type type = NULL;
    duckdb_data_chunk query_chunk = NULL;
    duckdb_data_chunk owned_chunk = NULL;
    duckdb_vector vector = NULL;
    memset(&result, 0, sizeof(result));
    /* Probe a populated query vector, not only a type-created empty vector: the
     * former is the shape DuckDB passes to a real UDF callback and catches the
     * historical failure where struct access worked on a synthetic type but not
     * on an actual VARIANT argument vector. */
    if (!connection || duckdb_query(connection, "SELECT {'rducks_probe': [1, NULL, 3]}::VARIANT", &result) != DuckDBSuccess) {
        duckdb_destroy_result(&result);
        return NULL;
    }
    /* result_get_chunk must not be mixed with legacy result column accessors;
     * obtain the owned canonical logical type directly from its real vector. */
    query_chunk = duckdb_result_get_chunk(result, 0);
    if (!query_chunk || duckdb_data_chunk_get_size(query_chunk) != 1) goto fail;
    vector = duckdb_data_chunk_get_vector(query_chunk, 0);
    type = vector ? duckdb_vector_get_column_type(vector) : NULL;
    if (!rducks_variant_logical_type_has_expected_layout(type) ||
        !rducks_variant_vector_has_expected_layout(vector)) goto fail;

    /* Also prove the canonical logical type can allocate the owned chunks used
     * by queued direct snapshots/results and by UDF registration cloning. */
    owned_chunk = duckdb_create_data_chunk(&type, 1);
    if (!owned_chunk) goto fail;
    vector = duckdb_data_chunk_get_vector(owned_chunk, 0);
    if (!rducks_variant_vector_has_expected_layout(vector)) goto fail;
    duckdb_destroy_data_chunk(&owned_chunk);
    duckdb_destroy_data_chunk(&query_chunk);
    duckdb_destroy_result(&result);
    return type;
fail:
    if (owned_chunk) duckdb_destroy_data_chunk(&owned_chunk);
    if (query_chunk) duckdb_destroy_data_chunk(&query_chunk);
    duckdb_destroy_result(&result);
    if (type) duckdb_destroy_logical_type(&type);
    return NULL;
}

static rducks_runtime_entry_t *rducks_runtime_get_or_create(duckdb_database database, duckdb_connection incoming_connection,
                                                            char *err, size_t err_cap) {
    rducks_runtime_entry_t *entry;
    int ready = 0;
    if (!database) {
        snprintf(err, err_cap, "Rducks extension did not receive a DuckDB database handle");
        return NULL;
    }

    rducks_runtime_lock();
    entry = rducks_runtime_find_locked(database);
    ready = entry ? entry->registration_surface_ready : 0;
    rducks_runtime_unlock();
    if (entry) {
        if (!ready || rducks_registration_surface_available(incoming_connection)) {
            return entry;
        }
        /* A retained process-lifetime runtime entry matched the raw database
         * address, but the incoming connection's catalog does not contain the
         * Rducks surface that should have been registered for that runtime.
         * Treat this as a stale database-address alias: keep the old entry
         * leaked/inert for safety, but detach it from future lookups so the new
         * database gets a fresh runtime id/token instead of stale R metadata.
         */
        rducks_runtime_lock();
        if (entry->database == database && entry->registration_surface_ready) {
            entry->database = NULL;
            entry->registration_surface_ready = 0;
            entry->generation++;
            g_runtime_stale_aliases++;
        }
        rducks_runtime_unlock();
    }

    rducks_runtime_lock();
    entry = rducks_runtime_find_locked(database);
    if (entry) {
        rducks_runtime_unlock();
        return entry;
    }
    if (!rducks_runtime_reserve_locked(g_runtime_count + 1)) {
        rducks_runtime_unlock();
        snprintf(err, err_cap, "failed to grow Rducks runtime registry");
        return NULL;
    }

    entry = (rducks_runtime_entry_t *)duckdb_malloc(sizeof(*entry));
    if (!entry) {
        rducks_runtime_unlock();
        snprintf(err, err_cap, "failed to allocate Rducks runtime entry");
        return NULL;
    }
    memset(entry, 0, sizeof(*entry));
    entry->database = database;
    entry->runtime_id = g_runtime_next_process_id++;
    entry->generation = 1;
    entry->execution_backend = RDUCKS_BACKEND_SINGLE;
    if (!rducks_runtime_queue_init_entry(entry)) {
        g_runtime_queue_init_failed++;
        duckdb_free(entry);
        rducks_runtime_unlock();
        snprintf(err, err_cap, "failed to initialize Rducks runtime queue");
        return NULL;
    }
    if (duckdb_connect(database, &entry->connection) == DuckDBError || !entry->connection) {
        g_runtime_connection_open_failed++;
        rducks_runtime_queue_destroy_entry(entry);
        memset(entry, 0, sizeof(*entry));
        duckdb_free(entry);
        rducks_runtime_unlock();
        snprintf(err, err_cap, "failed to open Rducks extension connection");
        return NULL;
    }
    g_runtime_connections_opened++;
    if (!rducks_runtime_configure_connection(entry->connection, err, err_cap)) {
        duckdb_disconnect(&entry->connection);
        g_runtime_connections_closed++;
        rducks_runtime_queue_destroy_entry(entry);
        memset(entry, 0, sizeof(*entry));
        duckdb_free(entry);
        rducks_runtime_unlock();
        return NULL;
    }
    /* Fail closed: only the SQL binder can currently construct a VARIANT
     * logical type with its required ExtraTypeInfo. Keep the canonical type
     * only if its complete physical layout is visible through generic C APIs. */
    entry->variant_logical_type = rducks_probe_variant_logical_type(entry->connection);
    if (duckdb_connect(database, &entry->query_stream_connection) == DuckDBError || !entry->query_stream_connection) {
        g_runtime_connection_open_failed++;
        duckdb_disconnect(&entry->connection);
        g_runtime_connections_closed++;
        if (entry->variant_logical_type) duckdb_destroy_logical_type(&entry->variant_logical_type);
        rducks_runtime_queue_destroy_entry(entry);
        memset(entry, 0, sizeof(*entry));
        duckdb_free(entry);
        rducks_runtime_unlock();
        snprintf(err, err_cap, "failed to open Rducks query stream connection");
        return NULL;
    }
    g_runtime_connections_opened++;
    if (!rducks_runtime_configure_connection(entry->query_stream_connection, err, err_cap)) {
        duckdb_disconnect(&entry->query_stream_connection);
        duckdb_disconnect(&entry->connection);
        g_runtime_connections_closed += 2;
        if (entry->variant_logical_type) duckdb_destroy_logical_type(&entry->variant_logical_type);
        rducks_runtime_queue_destroy_entry(entry);
        memset(entry, 0, sizeof(*entry));
        duckdb_free(entry);
        rducks_runtime_unlock();
        return NULL;
    }
    g_runtime_entries[g_runtime_count++] = entry;
    g_runtime_entries_created++;
    rducks_runtime_unlock();
    return entry;
}

static int rducks_rc_scalar_execute(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                    duckdb_data_chunk input, duckdb_vector output,
                                    char *err_msg, size_t err_cap);
static int rducks_rc_vectorized_execute(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                        duckdb_data_chunk input, duckdb_vector output,
                                        char *err_msg, size_t err_cap);
static int rducks_queue_submit_scalar(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                      rducks_r_scalar_local_state_t *local_state,
                                      duckdb_data_chunk input, duckdb_vector output,
                                      char *err_msg, size_t err_cap);
static int rducks_queue_submit_scalar_via_worker_on_main(rducks_runtime_entry_t *runtime,
                                                         rducks_r_scalar_meta_t *meta,
                                                         rducks_r_scalar_local_state_t *local_state,
                                                         duckdb_data_chunk input, duckdb_vector output,
                                                         char *err_msg, size_t err_cap);
static rducks_nng_client_pool_t *rducks_nng_client_pool_new(char **endpoints, size_t endpoint_count,
                                                            int timeout_ms, uint64_t max_pending,
                                                            char *err_msg, size_t err_cap);
static void rducks_nng_client_pool_destroy(rducks_nng_client_pool_t **pool_ptr);
static int rducks_nng_client_pool_request_reply_borrowed_acquired(rducks_nng_client_pool_t *pool,
                                                                  const uint8_t *request, size_t request_size,
                                                                  void **response_msg_out,
                                                                  const uint8_t **response_body_out,
                                                                  size_t *response_size_out,
                                                                  char *err_msg, size_t err_cap);
static void rducks_nng_response_msg_free(void *response_msg);
static int rducks_queue_drain_on_main(rducks_runtime_entry_t *runtime, int max_requests);
static int rducks_queue_self_test(rducks_runtime_entry_t *runtime, uint64_t iterations,
                                  uint64_t *out_value, char *err_msg, size_t err_cap);
static int rducks_queue_self_test_cancel_after(rducks_runtime_entry_t *runtime, uint64_t iterations,
                                               uint64_t cancel_after,
                                               uint64_t *out_value, char *err_msg, size_t err_cap);
/* Implementation modules are included into one translation unit because
 * DuckDB loads a single extension shared object built by configure.
 */
#include "src/rducks_threads.c"
#include "src/rducks_util.c"
#include "src/rducks_types.c"
#include "src/rducks_runtime.c"
#include "src/rducks_nng.c"
/* Defined in src/rducks_ripc.c (included after rducks_rc.c); forward-declared so
 * the scalar dispatch in rducks_scalar_dispatch.c can route wire (RIPC) UDFs to it. */
static int rducks_ripc_execute(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                               duckdb_data_chunk input, duckdb_vector output,
                               char *err_msg, size_t err_cap);
#include "src/rducks_scalar_dispatch.c"
#include "src/rducks_rc.c"
#include "src/quack_core.c"
#include "src/rducks_ripc.c"
#include "src/rducks_worker_queue.c"
#include "src/rducks_parallel.c"
#include "src/rducks_udf_sql.c"
#include "src/rducks_aggregate.c"
#include "src/rducks_table.c"
#include "src/rducks_query_stream.c"
#include "src/rducks_surfaces.c"
