/* Included by ../rducks_extension.c. */

static int rducks_dev_surfaces_enabled(void) {
    const char *value = getenv("RDUCKS_DEV_SURFACES");
    char lowered[8];
    size_t i;
    if (!value || !value[0]) return 0;
    for (i = 0; i < sizeof(lowered) - 1U && value[i]; i++) {
        lowered[i] = (char)tolower((unsigned char)value[i]);
    }
    lowered[i] = '\0';
    return strcmp(lowered, "1") == 0 || strcmp(lowered, "true") == 0 ||
           strcmp(lowered, "yes") == 0 || strcmp(lowered, "on") == 0;
}

static void rducks_version_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    (void)info;
    idx_t n = duckdb_data_chunk_get_size(input);
    for (idx_t i = 0; i < n; i++) {
        duckdb_vector_assign_string_element(output, i, "Rducks extension loaded");
    }
}

static bool rducks_register_scalar_surface(duckdb_connection con, rducks_runtime_entry_t *runtime) {
    duckdb_scalar_function fn = duckdb_create_scalar_function();
    duckdb_logical_type varchar_type = duckdb_create_logical_type(DUCKDB_TYPE_VARCHAR);
    duckdb_logical_type bool_type = duckdb_create_logical_type(DUCKDB_TYPE_BOOLEAN);
    duckdb_state rc;
    if (!fn || !varchar_type || !bool_type) {
        if (fn) {
            duckdb_destroy_scalar_function(&fn);
        }
        if (varchar_type) {
            duckdb_destroy_logical_type(&varchar_type);
        }
        if (bool_type) {
            duckdb_destroy_logical_type(&bool_type);
        }
        return false;
    }
    duckdb_scalar_function_set_name(fn, "rducks_register_scalar");
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, bool_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_set_return_type(fn, bool_type);
    duckdb_scalar_function_set_volatile(fn);
    duckdb_scalar_function_set_extra_info(fn, runtime, NULL);
    duckdb_scalar_function_set_function(fn, rducks_register_scalar_scalar);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&varchar_type);
    duckdb_destroy_logical_type(&bool_type);
    return rc == DuckDBSuccess;
}

static bool rducks_register_table_surface(duckdb_connection con, rducks_runtime_entry_t *runtime) {
    duckdb_scalar_function fn = duckdb_create_scalar_function();
    duckdb_logical_type varchar_type = duckdb_create_logical_type(DUCKDB_TYPE_VARCHAR);
    duckdb_logical_type bool_type = duckdb_create_logical_type(DUCKDB_TYPE_BOOLEAN);
    duckdb_logical_type ubigint_type = duckdb_create_logical_type(DUCKDB_TYPE_UBIGINT);
    duckdb_state rc;
    if (!fn || !varchar_type || !bool_type || !ubigint_type) {
        if (fn) duckdb_destroy_scalar_function(&fn);
        if (varchar_type) duckdb_destroy_logical_type(&varchar_type);
        if (bool_type) duckdb_destroy_logical_type(&bool_type);
        if (ubigint_type) duckdb_destroy_logical_type(&ubigint_type);
        return false;
    }
    duckdb_scalar_function_set_name(fn, "rducks_register_table");
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, ubigint_type);
    duckdb_scalar_function_add_parameter(fn, ubigint_type);
    duckdb_scalar_function_set_return_type(fn, bool_type);
    duckdb_scalar_function_set_volatile(fn);
    duckdb_scalar_function_set_extra_info(fn, runtime, NULL);
    duckdb_scalar_function_set_function(fn, rducks_register_table_scalar);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&varchar_type);
    duckdb_destroy_logical_type(&bool_type);
    duckdb_destroy_logical_type(&ubigint_type);
    return rc == DuckDBSuccess;
}

static bool rducks_register_aggregate_surface(duckdb_connection con, rducks_runtime_entry_t *runtime) {
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
    duckdb_scalar_function_set_name(fn, "rducks_register_aggregate");
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_set_return_type(fn, bool_type);
    duckdb_scalar_function_set_volatile(fn);
    duckdb_scalar_function_set_extra_info(fn, runtime, NULL);
    duckdb_scalar_function_set_function(fn, rducks_register_aggregate_scalar);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&varchar_type);
    duckdb_destroy_logical_type(&bool_type);
    return rc == DuckDBSuccess;
}

static bool rducks_register_unary_varchar_bool_surface_ex(duckdb_connection con, rducks_runtime_entry_t *runtime,
                                                          const char *name, duckdb_scalar_function_t callback,
                                                          bool special_handling) {
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
    duckdb_scalar_function_set_name(fn, name);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_set_return_type(fn, bool_type);
    if (special_handling) duckdb_scalar_function_set_special_handling(fn);
    duckdb_scalar_function_set_volatile(fn);
    duckdb_scalar_function_set_extra_info(fn, runtime, NULL);
    duckdb_scalar_function_set_function(fn, callback);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&varchar_type);
    duckdb_destroy_logical_type(&bool_type);
    return rc == DuckDBSuccess;
}

static bool rducks_register_unary_varchar_bool_surface(duckdb_connection con, rducks_runtime_entry_t *runtime,
                                                       const char *name, duckdb_scalar_function_t callback) {
    return rducks_register_unary_varchar_bool_surface_ex(con, runtime, name, callback, false);
}

static bool rducks_register_noarg_scalar_ex(duckdb_connection con, rducks_runtime_entry_t *runtime,
                                            const char *name, duckdb_type return_type,
                                            duckdb_scalar_function_t callback, bool is_volatile);

static bool rducks_register_binary_varchar_surface(duckdb_connection con, rducks_runtime_entry_t *runtime,
                                                   const char *name, duckdb_scalar_function_t callback) {
    duckdb_scalar_function fn = duckdb_create_scalar_function();
    duckdb_logical_type varchar_type = duckdb_create_logical_type(DUCKDB_TYPE_VARCHAR);
    duckdb_state rc;
    if (!fn || !varchar_type) {
        if (fn) duckdb_destroy_scalar_function(&fn);
        if (varchar_type) duckdb_destroy_logical_type(&varchar_type);
        return false;
    }
    duckdb_scalar_function_set_name(fn, name);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_set_return_type(fn, varchar_type);
    duckdb_scalar_function_set_volatile(fn);
    duckdb_scalar_function_set_extra_info(fn, runtime, NULL);
    duckdb_scalar_function_set_function(fn, callback);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&varchar_type);
    return rc == DuckDBSuccess;
}

static bool rducks_register_udf_stat_surface(duckdb_connection con, rducks_runtime_entry_t *runtime) {
    bool ok = rducks_register_binary_varchar_surface(con, runtime, "rducks_udf_stat", rducks_udf_stat_scalar);
    if (!ok) return false;
    /* Optional diagnostics helper. If a user/session name collision prevents
     * registration, R uses its documented compatibility field list instead of
     * querying this native discovery surface. */
    (void)rducks_register_noarg_scalar_ex(con, runtime, "rducks_udf_stat_fields", DUCKDB_TYPE_VARCHAR,
                                          rducks_udf_stat_fields_scalar, false);
    return rducks_register_unary_varchar_bool_surface_ex(con, runtime, "rducks_reset_udf_stats",
                                                         rducks_reset_udf_stats_scalar, true);
}

static bool rducks_register_main_thread_token_surface(duckdb_connection con, rducks_runtime_entry_t *runtime) {
    return rducks_register_unary_varchar_bool_surface(con, runtime, "rducks_set_main_thread_token",
                                                      rducks_set_main_thread_token_scalar);
}

static const char *rducks_execution_backend_name(rducks_runtime_entry_t *runtime) {
    switch (rducks_get_execution_backend(runtime)) {
    case RDUCKS_BACKEND_SINGLE:
        return "single";
    case RDUCKS_BACKEND_CONCURRENT_INPROC:
        return "concurrent_inproc";
    case RDUCKS_BACKEND_MULTIPROCESS_PARALLEL:
        return "multiprocess_parallel";
    default:
        return "unknown";
    }
}

static void rducks_execution_backend_stat_scalar(duckdb_function_info info, duckdb_data_chunk input,
                                                 duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    const char *name = runtime ? rducks_execution_backend_name(runtime) : "unknown";
    for (idx_t i = 0; i < n; i++) duckdb_vector_assign_string_element(output, i, name);
}

static bool rducks_register_execution_backend_surface(duckdb_connection con, rducks_runtime_entry_t *runtime) {
    return rducks_register_noarg_scalar_ex(con, runtime, "rducks_execution_backend", DUCKDB_TYPE_VARCHAR,
                                           rducks_execution_backend_stat_scalar, true) &&
           rducks_register_unary_varchar_bool_surface(con, runtime, "rducks_set_execution_backend",
                                                      rducks_set_execution_backend_scalar);
}

static bool rducks_register_noarg_scalar_ex(duckdb_connection con, rducks_runtime_entry_t *runtime,
                                             const char *name, duckdb_type return_type,
                                             duckdb_scalar_function_t callback, bool is_volatile) {
    duckdb_scalar_function fn = duckdb_create_scalar_function();
    duckdb_logical_type logical_type = duckdb_create_logical_type(return_type);
    duckdb_state rc;
    if (!fn || !logical_type) {
        if (fn) duckdb_destroy_scalar_function(&fn);
        if (logical_type) duckdb_destroy_logical_type(&logical_type);
        return false;
    }
    duckdb_scalar_function_set_name(fn, name);
    duckdb_scalar_function_set_return_type(fn, logical_type);
    if (is_volatile) duckdb_scalar_function_set_volatile(fn);
    if (runtime) duckdb_scalar_function_set_extra_info(fn, runtime, NULL);
    duckdb_scalar_function_set_function(fn, callback);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_logical_type(&logical_type);
    duckdb_destroy_scalar_function(&fn);
    return rc == DuckDBSuccess;
}

static bool rducks_register_noarg_scalar(duckdb_connection con, const char *name, duckdb_type return_type,
                                          duckdb_scalar_function_t callback, bool is_volatile) {
    return rducks_register_noarg_scalar_ex(con, NULL, name, return_type, callback, is_volatile);
}

typedef enum rducks_queue_stat_field {
    RDUCKS_QUEUE_STAT_SUBMITTED = 0,
    RDUCKS_QUEUE_STAT_EXECUTED,
    RDUCKS_QUEUE_STAT_TIMEOUTS,
    RDUCKS_QUEUE_STAT_PENDING_CURRENT,
    RDUCKS_QUEUE_STAT_PENDING_MAX,
    RDUCKS_QUEUE_STAT_RUNNING_CURRENT,
    RDUCKS_QUEUE_STAT_RUNNING_MAX,
    RDUCKS_QUEUE_STAT_MAIN_DRAINS,
    RDUCKS_QUEUE_STAT_MAIN_DRAIN_BATCHES,
    RDUCKS_QUEUE_STAT_MAIN_DRAIN_MAX_BATCH
} rducks_queue_stat_field_t;

static uint64_t rducks_queue_stat_value_locked(rducks_runtime_entry_t *runtime,
                                               rducks_queue_stat_field_t field) {
    switch (field) {
    case RDUCKS_QUEUE_STAT_SUBMITTED:
        return runtime->queue_submitted;
    case RDUCKS_QUEUE_STAT_EXECUTED:
        return runtime->queue_executed;
    case RDUCKS_QUEUE_STAT_TIMEOUTS:
        return runtime->queue_timeouts;
    case RDUCKS_QUEUE_STAT_PENDING_CURRENT:
        return runtime->queue_pending_current;
    case RDUCKS_QUEUE_STAT_PENDING_MAX:
        return runtime->queue_pending_max;
    case RDUCKS_QUEUE_STAT_RUNNING_CURRENT:
        return runtime->queue_running_current;
    case RDUCKS_QUEUE_STAT_RUNNING_MAX:
        return runtime->queue_running_max;
    case RDUCKS_QUEUE_STAT_MAIN_DRAINS:
        return runtime->queue_main_drains;
    case RDUCKS_QUEUE_STAT_MAIN_DRAIN_BATCHES:
        return runtime->queue_main_drain_batches;
    case RDUCKS_QUEUE_STAT_MAIN_DRAIN_MAX_BATCH:
        return runtime->queue_main_drain_max_batch;
    default:
        return 0;
    }
}

static void rducks_queue_stat_scalar_impl(duckdb_function_info info, duckdb_data_chunk input,
                                          duckdb_vector output, rducks_queue_stat_field_t field) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    uint64_t value = 0;
    idx_t n = duckdb_data_chunk_get_size(input);
    uint64_t *out = (uint64_t *)duckdb_vector_get_data(output);
    if (runtime) {
        rducks_queue_lock(runtime);
        value = rducks_queue_stat_value_locked(runtime, field);
        rducks_queue_unlock(runtime);
    }
    for (idx_t i = 0; i < n; i++) out[i] = value;
}

#define RDUCKS_QUEUE_STAT_SURFACES(X) \
    X("rducks_queue_submitted", rducks_queue_submitted_stat_scalar, RDUCKS_QUEUE_STAT_SUBMITTED) \
    X("rducks_queue_executed", rducks_queue_executed_stat_scalar, RDUCKS_QUEUE_STAT_EXECUTED) \
    X("rducks_queue_timeouts", rducks_queue_timeouts_stat_scalar, RDUCKS_QUEUE_STAT_TIMEOUTS) \
    X("rducks_queue_pending_current", rducks_queue_pending_current_stat_scalar, RDUCKS_QUEUE_STAT_PENDING_CURRENT) \
    X("rducks_queue_pending_max", rducks_queue_pending_max_stat_scalar, RDUCKS_QUEUE_STAT_PENDING_MAX) \
    X("rducks_queue_running_current", rducks_queue_running_current_stat_scalar, RDUCKS_QUEUE_STAT_RUNNING_CURRENT) \
    X("rducks_queue_running_max", rducks_queue_running_max_stat_scalar, RDUCKS_QUEUE_STAT_RUNNING_MAX) \
    X("rducks_queue_main_drains", rducks_queue_main_drains_stat_scalar, RDUCKS_QUEUE_STAT_MAIN_DRAINS) \
    X("rducks_queue_main_drain_batches", rducks_queue_main_drain_batches_stat_scalar, RDUCKS_QUEUE_STAT_MAIN_DRAIN_BATCHES) \
    X("rducks_queue_main_drain_max_batch", rducks_queue_main_drain_max_batch_stat_scalar, RDUCKS_QUEUE_STAT_MAIN_DRAIN_MAX_BATCH)

#define RDUCKS_DEFINE_QUEUE_STAT_SCALAR(name, fn, field) \
    static void fn(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) { \
        rducks_queue_stat_scalar_impl(info, input, output, field); \
    }

RDUCKS_QUEUE_STAT_SURFACES(RDUCKS_DEFINE_QUEUE_STAT_SCALAR)

#undef RDUCKS_DEFINE_QUEUE_STAT_SCALAR

typedef enum rducks_preserved_release_stat_field {
    RDUCKS_RELEASE_STAT_QUEUED = 0,
    RDUCKS_RELEASE_STAT_RELEASED,
    RDUCKS_RELEASE_STAT_FAILED,
    RDUCKS_RELEASE_STAT_PENDING
} rducks_preserved_release_stat_field_t;

static void rducks_preserved_release_stat_scalar_impl(duckdb_function_info info, duckdb_data_chunk input,
                                                      duckdb_vector output,
                                                      rducks_preserved_release_stat_field_t field) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    uint64_t queued = 0;
    uint64_t released = 0;
    uint64_t failed = 0;
    uint64_t pending = 0;
    uint64_t value = 0;
    idx_t n = duckdb_data_chunk_get_size(input);
    uint64_t *out = (uint64_t *)duckdb_vector_get_data(output);
    if (runtime) rducks_preserved_release_drain_on_main(runtime);
    rducks_preserved_release_snapshot(&queued, &released, &failed, &pending);
    switch (field) {
    case RDUCKS_RELEASE_STAT_QUEUED:
        value = queued;
        break;
    case RDUCKS_RELEASE_STAT_RELEASED:
        value = released;
        break;
    case RDUCKS_RELEASE_STAT_FAILED:
        value = failed;
        break;
    case RDUCKS_RELEASE_STAT_PENDING:
        value = pending;
        break;
    default:
        value = 0;
        break;
    }
    for (idx_t i = 0; i < n; i++) out[i] = value;
}

#define RDUCKS_RELEASE_STAT_SURFACES(X) \
    X("rducks_release_queue_queued", rducks_release_queued_stat_scalar, RDUCKS_RELEASE_STAT_QUEUED) \
    X("rducks_release_queue_released", rducks_release_released_stat_scalar, RDUCKS_RELEASE_STAT_RELEASED) \
    X("rducks_release_queue_failed", rducks_release_failed_stat_scalar, RDUCKS_RELEASE_STAT_FAILED) \
    X("rducks_release_queue_pending", rducks_release_pending_stat_scalar, RDUCKS_RELEASE_STAT_PENDING)

#define RDUCKS_DEFINE_RELEASE_STAT_SCALAR(name, fn, field) \
    static void fn(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) { \
        rducks_preserved_release_stat_scalar_impl(info, input, output, field); \
    }

RDUCKS_RELEASE_STAT_SURFACES(RDUCKS_DEFINE_RELEASE_STAT_SCALAR)

#undef RDUCKS_DEFINE_RELEASE_STAT_SCALAR

typedef enum rducks_runtime_stat_field {
    RDUCKS_RUNTIME_STAT_REGISTRY_ENTRIES = 0,
    RDUCKS_RUNTIME_STAT_ACTIVE_ENTRIES,
    RDUCKS_RUNTIME_STAT_STALE_ENTRIES,
    RDUCKS_RUNTIME_STAT_ENTRIES_CREATED,
    RDUCKS_RUNTIME_STAT_STALE_ALIASES,
    RDUCKS_RUNTIME_STAT_CONNECTIONS_OPENED,
    RDUCKS_RUNTIME_STAT_CONNECTIONS_CLOSED,
    RDUCKS_RUNTIME_STAT_CONNECTION_OPEN_FAILED,
    RDUCKS_RUNTIME_STAT_QUEUE_INIT_FAILED
} rducks_runtime_stat_field_t;

static uint64_t rducks_runtime_stat_value_locked(rducks_runtime_stat_field_t field) {
    uint64_t active = 0;
    uint64_t stale = 0;
    for (idx_t i = 0; i < g_runtime_count; i++) {
        if (!g_runtime_entries[i]) continue;
        if (g_runtime_entries[i]->database) active++;
        else stale++;
    }
    switch (field) {
    case RDUCKS_RUNTIME_STAT_REGISTRY_ENTRIES:
        return (uint64_t)g_runtime_count;
    case RDUCKS_RUNTIME_STAT_ACTIVE_ENTRIES:
        return active;
    case RDUCKS_RUNTIME_STAT_STALE_ENTRIES:
        return stale;
    case RDUCKS_RUNTIME_STAT_ENTRIES_CREATED:
        return g_runtime_entries_created;
    case RDUCKS_RUNTIME_STAT_STALE_ALIASES:
        return g_runtime_stale_aliases;
    case RDUCKS_RUNTIME_STAT_CONNECTIONS_OPENED:
        return g_runtime_connections_opened;
    case RDUCKS_RUNTIME_STAT_CONNECTIONS_CLOSED:
        return g_runtime_connections_closed;
    case RDUCKS_RUNTIME_STAT_CONNECTION_OPEN_FAILED:
        return g_runtime_connection_open_failed;
    case RDUCKS_RUNTIME_STAT_QUEUE_INIT_FAILED:
        return g_runtime_queue_init_failed;
    default:
        return 0;
    }
}

static void rducks_runtime_stat_scalar_impl(duckdb_function_info info, duckdb_data_chunk input,
                                            duckdb_vector output, rducks_runtime_stat_field_t field) {
    (void)info;
    idx_t n = duckdb_data_chunk_get_size(input);
    uint64_t *out = (uint64_t *)duckdb_vector_get_data(output);
    uint64_t value;
    /* This scalar executes inside DuckDB. Use a non-blocking registry-lock
     * attempt so diagnostics cannot deadlock behind rducks_enable() code that
     * may be holding the registry lock while entering DuckDB connection APIs.
     */
    if (!rducks_runtime_try_lock()) {
        duckdb_scalar_function_set_error(info, "Rducks runtime stats are temporarily unavailable");
        return;
    }
    value = rducks_runtime_stat_value_locked(field);
    rducks_runtime_unlock();
    for (idx_t i = 0; i < n; i++) out[i] = value;
}

#define RDUCKS_RUNTIME_STAT_SURFACES(X) \
    X("rducks_runtime_registry_entries", rducks_runtime_registry_entries_stat_scalar, RDUCKS_RUNTIME_STAT_REGISTRY_ENTRIES) \
    X("rducks_runtime_active_entries", rducks_runtime_active_entries_stat_scalar, RDUCKS_RUNTIME_STAT_ACTIVE_ENTRIES) \
    X("rducks_runtime_stale_entries", rducks_runtime_stale_entries_stat_scalar, RDUCKS_RUNTIME_STAT_STALE_ENTRIES) \
    X("rducks_runtime_entries_created", rducks_runtime_entries_created_stat_scalar, RDUCKS_RUNTIME_STAT_ENTRIES_CREATED) \
    X("rducks_runtime_stale_aliases", rducks_runtime_stale_aliases_stat_scalar, RDUCKS_RUNTIME_STAT_STALE_ALIASES) \
    X("rducks_runtime_connections_opened", rducks_runtime_connections_opened_stat_scalar, RDUCKS_RUNTIME_STAT_CONNECTIONS_OPENED) \
    X("rducks_runtime_connections_closed", rducks_runtime_connections_closed_stat_scalar, RDUCKS_RUNTIME_STAT_CONNECTIONS_CLOSED) \
    X("rducks_runtime_connection_open_failed", rducks_runtime_connection_open_failed_stat_scalar, RDUCKS_RUNTIME_STAT_CONNECTION_OPEN_FAILED) \
    X("rducks_runtime_queue_init_failed", rducks_runtime_queue_init_failed_stat_scalar, RDUCKS_RUNTIME_STAT_QUEUE_INIT_FAILED)

#define RDUCKS_DEFINE_RUNTIME_STAT_SCALAR(name, fn, field) \
    static void fn(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) { \
        rducks_runtime_stat_scalar_impl(info, input, output, field); \
    }

RDUCKS_RUNTIME_STAT_SURFACES(RDUCKS_DEFINE_RUNTIME_STAT_SCALAR)

#undef RDUCKS_DEFINE_RUNTIME_STAT_SCALAR

static void rducks_queue_self_test_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    uint64_t *iterations = (uint64_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 0));
    uint64_t *out = (uint64_t *)duckdb_vector_get_data(output);
    for (idx_t i = 0; i < n; i++) {
        char err[256];
        uint64_t value = 0;
        err[0] = '\0';
        if (!rducks_queue_self_test(runtime, iterations[i], &value, err, sizeof(err))) {
            duckdb_scalar_function_set_error(info, err[0] ? err : "Rducks queue self-test failed");
            return;
        }
        out[i] = value;
    }
}

static bool rducks_register_unary_ubigint_typed_surface(duckdb_connection con, rducks_runtime_entry_t *runtime,
                                                        const char *name, duckdb_type return_type,
                                                        duckdb_scalar_function_t callback) {
    duckdb_scalar_function fn = duckdb_create_scalar_function();
    duckdb_logical_type ubigint_type = duckdb_create_logical_type(DUCKDB_TYPE_UBIGINT);
    duckdb_logical_type out_type = duckdb_create_logical_type(return_type);
    duckdb_state rc;
    if (!fn || !ubigint_type || !out_type) {
        if (fn) duckdb_destroy_scalar_function(&fn);
        if (ubigint_type) duckdb_destroy_logical_type(&ubigint_type);
        if (out_type) duckdb_destroy_logical_type(&out_type);
        return false;
    }
    duckdb_scalar_function_set_name(fn, name);
    duckdb_scalar_function_add_parameter(fn, ubigint_type);
    duckdb_scalar_function_set_return_type(fn, out_type);
    duckdb_scalar_function_set_volatile(fn);
    duckdb_scalar_function_set_extra_info(fn, runtime, NULL);
    duckdb_scalar_function_set_function(fn, callback);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&ubigint_type);
    duckdb_destroy_logical_type(&out_type);
    return rc == DuckDBSuccess;
}

static bool rducks_register_unary_ubigint_surface(duckdb_connection con, rducks_runtime_entry_t *runtime,
                                                  const char *name, duckdb_scalar_function_t callback) {
    return rducks_register_unary_ubigint_typed_surface(con, runtime, name, DUCKDB_TYPE_UBIGINT, callback);
}

static void rducks_queue_pending_timeout_ms_scalar(duckdb_function_info info, duckdb_data_chunk input,
                                                   duckdb_vector output) {
    (void)info;
    idx_t n = duckdb_data_chunk_get_size(input);
    uint64_t *out = (uint64_t *)duckdb_vector_get_data(output);
    uint64_t value = RDUCKS_QUEUE_PENDING_TIMEOUT_MS;
    for (idx_t i = 0; i < n; i++) out[i] = value;
}

static void rducks_queue_running_timeout_supported_scalar(duckdb_function_info info, duckdb_data_chunk input,
                                                          duckdb_vector output) {
    (void)info;
    idx_t n = duckdb_data_chunk_get_size(input);
    bool *out = (bool *)duckdb_vector_get_data(output);
    for (idx_t i = 0; i < n; i++) out[i] = false;
}

static void rducks_thread_is_main_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    bool *out = (bool *)duckdb_vector_get_data(output);
    bool is_main = runtime && rducks_is_main_thread(runtime);
    for (idx_t i = 0; i < n; i++) out[i] = is_main;
}

typedef struct rducks_noarg_surface_def {
    const char *name;
    duckdb_type return_type;
    duckdb_scalar_function_t callback;
    bool volatile_fn;
} rducks_noarg_surface_def_t;

#define RDUCKS_NOARG_SURFACE_FROM_QUEUE_STAT(name, fn, field) { name, DUCKDB_TYPE_UBIGINT, fn, true },
#define RDUCKS_NOARG_SURFACE_FROM_RELEASE_STAT(name, fn, field) { name, DUCKDB_TYPE_UBIGINT, fn, true },
#define RDUCKS_NOARG_SURFACE_FROM_RUNTIME_STAT(name, fn, field) { name, DUCKDB_TYPE_UBIGINT, fn, true },

static const rducks_noarg_surface_def_t rducks_queue_stat_surface_defs[] = {
    RDUCKS_QUEUE_STAT_SURFACES(RDUCKS_NOARG_SURFACE_FROM_QUEUE_STAT)
    { "rducks_queue_pending_timeout_ms", DUCKDB_TYPE_UBIGINT, rducks_queue_pending_timeout_ms_scalar, false },
    { "rducks_queue_running_timeout_supported", DUCKDB_TYPE_BOOLEAN, rducks_queue_running_timeout_supported_scalar, false },
    RDUCKS_RELEASE_STAT_SURFACES(RDUCKS_NOARG_SURFACE_FROM_RELEASE_STAT)
    RDUCKS_RUNTIME_STAT_SURFACES(RDUCKS_NOARG_SURFACE_FROM_RUNTIME_STAT)
    { "rducks_nng_quiesce", DUCKDB_TYPE_BOOLEAN, rducks_nng_quiesce_scalar, true }
};

#undef RDUCKS_NOARG_SURFACE_FROM_QUEUE_STAT
#undef RDUCKS_NOARG_SURFACE_FROM_RELEASE_STAT
#undef RDUCKS_NOARG_SURFACE_FROM_RUNTIME_STAT

static bool rducks_register_noarg_surfaces(duckdb_connection con, rducks_runtime_entry_t *runtime,
                                           const rducks_noarg_surface_def_t *defs, size_t count) {
    for (size_t i = 0U; i < count; i++) {
        if (!rducks_register_noarg_scalar_ex(con, runtime, defs[i].name, defs[i].return_type,
                                             defs[i].callback, defs[i].volatile_fn)) {
            return false;
        }
    }
    return true;
}

static bool rducks_register_queue_stats(duckdb_connection con, rducks_runtime_entry_t *runtime) {
    return rducks_register_noarg_surfaces(
        con, runtime, rducks_queue_stat_surface_defs,
        sizeof(rducks_queue_stat_surface_defs) / sizeof(rducks_queue_stat_surface_defs[0]));
}

static bool rducks_register_dev_diagnostic_surfaces(duckdb_connection con, rducks_runtime_entry_t *runtime) {
    if (!rducks_dev_surfaces_enabled()) return true;
    return rducks_register_parallel_range(con) &&
           rducks_register_parallel_thread_probe(con, runtime) &&
           rducks_register_unary_ubigint_surface(con, runtime, "rducks_queue_self_test",
                                                 rducks_queue_self_test_scalar) &&
           rducks_register_unary_ubigint_typed_surface(con, runtime, "rducks_thread_is_main",
                                                       DUCKDB_TYPE_BOOLEAN, rducks_thread_is_main_scalar) &&
           rducks_register_noarg_scalar_ex(con, runtime, "rducks_nng_enabled", DUCKDB_TYPE_BOOLEAN,
                                           rducks_nng_enabled_scalar, false) &&
           rducks_register_noarg_scalar_ex(con, runtime, "rducks_nng_version", DUCKDB_TYPE_VARCHAR,
                                           rducks_nng_version_scalar, false) &&
           rducks_register_noarg_scalar_ex(con, runtime, "rducks_nng_self_test", DUCKDB_TYPE_BOOLEAN,
                                           rducks_nng_self_test_scalar, true);
}

static void rducks_runtime_token_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    char token[96];
    if (!runtime) {
        duckdb_scalar_function_set_error(info, "Rducks runtime is not initialized for this connection");
        return;
    }
    rducks_preserved_release_drain_on_main(runtime);
    rducks_runtime_lock();
    snprintf(token, sizeof(token), "rducks-runtime-%llu-%llu",
             (unsigned long long)runtime->runtime_id,
             (unsigned long long)runtime->generation);
    rducks_runtime_unlock();
    for (idx_t i = 0; i < n; i++) {
        duckdb_vector_assign_string_element(output, i, token);
    }
}

static bool rducks_register_runtime_token(duckdb_connection con, rducks_runtime_entry_t *runtime) {
    return rducks_register_noarg_scalar_ex(con, runtime, "rducks_runtime_token", DUCKDB_TYPE_VARCHAR,
                                           rducks_runtime_token_scalar, false);
}

static bool rducks_query_stream_require_runtime(duckdb_function_info info, rducks_runtime_entry_t *runtime) {
    if (!runtime) {
        duckdb_scalar_function_set_error(info, "Rducks runtime is not initialized for this connection");
        return false;
    }
    return true;
}

static bool rducks_query_stream_copy_nonnull_arg(duckdb_function_info info, duckdb_string_t *values,
                                                 uint64_t *validity, idx_t row,
                                                 const char *null_error, const char *oom_error,
                                                 char **out) {
    *out = NULL;
    if (validity && !duckdb_validity_row_is_valid(validity, row)) {
        duckdb_scalar_function_set_error(info, null_error);
        return false;
    }
    *out = rducks_copy_duckdb_string(&values[row]);
    if (!*out) {
        duckdb_scalar_function_set_error(info, oom_error);
        return false;
    }
    return true;
}

static void rducks_query_stream_open_scalar(duckdb_function_info info, duckdb_data_chunk input,
                                            duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    duckdb_vector sql_vector = duckdb_data_chunk_get_vector(input, 0);
    duckdb_string_t *sql_values = (duckdb_string_t *)duckdb_vector_get_data(sql_vector);
    uint64_t *validity = duckdb_vector_get_validity(sql_vector);
    if (!rducks_query_stream_require_runtime(info, runtime)) return;
    for (idx_t i = 0; i < n; i++) {
        char *sql;
        const char *token = NULL;
        char err[512];
        err[0] = '\0';
        if (!rducks_query_stream_copy_nonnull_arg(info, sql_values, validity, i,
                                                  "Rducks query stream SQL must not be NULL",
                                                  "out of memory opening Rducks query stream", &sql)) {
            return;
        }
        if (!rducks_query_stream_open_native(runtime, sql, &token, err, sizeof(err))) {
            free(sql);
            duckdb_scalar_function_set_error(info, err[0] ? err : "failed to open Rducks query stream");
            return;
        }
        duckdb_vector_assign_string_element(output, i, token ? token : "");
        free(sql);
    }
}

static void rducks_query_stream_schema_scalar(duckdb_function_info info, duckdb_data_chunk input,
                                              duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    duckdb_vector token_vector = duckdb_data_chunk_get_vector(input, 0);
    duckdb_string_t *tokens = (duckdb_string_t *)duckdb_vector_get_data(token_vector);
    uint64_t *validity = duckdb_vector_get_validity(token_vector);
    bool *out = (bool *)duckdb_vector_get_data(output);
    if (!rducks_query_stream_require_runtime(info, runtime)) return;
    for (idx_t i = 0; i < n; i++) {
        char *token;
        char err[512];
        err[0] = '\0';
        if (!rducks_query_stream_copy_nonnull_arg(info, tokens, validity, i,
                                                  "Rducks query stream token must not be NULL",
                                                  "out of memory reading Rducks query stream schema", &token)) {
            return;
        }
        if (!rducks_query_stream_schema_native(runtime, token, err, sizeof(err))) {
            free(token);
            duckdb_scalar_function_set_error(info, err[0] ? err : "failed to read Rducks query stream schema");
            return;
        }
        out[i] = true;
        free(token);
    }
}

static void rducks_query_stream_next_scalar(duckdb_function_info info, duckdb_data_chunk input,
                                            duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    duckdb_vector token_vector = duckdb_data_chunk_get_vector(input, 0);
    duckdb_string_t *tokens = (duckdb_string_t *)duckdb_vector_get_data(token_vector);
    uint64_t *validity = duckdb_vector_get_validity(token_vector);
    bool *out = (bool *)duckdb_vector_get_data(output);
    if (!rducks_query_stream_require_runtime(info, runtime)) return;
    for (idx_t i = 0; i < n; i++) {
        char *token;
        int has_batch = 0;
        char err[512];
        err[0] = '\0';
        if (!rducks_query_stream_copy_nonnull_arg(info, tokens, validity, i,
                                                  "Rducks query stream token must not be NULL",
                                                  "out of memory fetching Rducks query stream batch", &token)) {
            return;
        }
        if (!rducks_query_stream_next_native(runtime, token, &has_batch, err, sizeof(err))) {
            free(token);
            duckdb_scalar_function_set_error(info, err[0] ? err : "failed to fetch Rducks query stream batch");
            return;
        }
        out[i] = has_batch ? true : false;
        free(token);
    }
}

static void rducks_query_stream_close_scalar(duckdb_function_info info, duckdb_data_chunk input,
                                             duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    duckdb_vector token_vector = duckdb_data_chunk_get_vector(input, 0);
    duckdb_string_t *tokens = (duckdb_string_t *)duckdb_vector_get_data(token_vector);
    uint64_t *validity = duckdb_vector_get_validity(token_vector);
    bool *out = (bool *)duckdb_vector_get_data(output);
    if (!rducks_query_stream_require_runtime(info, runtime)) return;
    {
        char err[256];
        err[0] = '\0';
        if (!rducks_allow_calling_thread_r_execution(runtime, err, sizeof(err))) {
            duckdb_scalar_function_set_error(info, err[0] ? err : "Rducks query stream close reached a non-calling DuckDB execution thread");
            return;
        }
    }
    for (idx_t i = 0; i < n; i++) {
        char *token;
        int closed = 0;
        if (validity && !duckdb_validity_row_is_valid(validity, i)) {
            out[i] = false;
            continue;
        }
        token = rducks_copy_duckdb_string(&tokens[i]);
        if (!token) {
            duckdb_scalar_function_set_error(info, "out of memory closing Rducks query stream");
            return;
        }
        rducks_query_stream_close_native(runtime, token, &closed);
        out[i] = closed ? true : false;
        free(token);
    }
}

static bool rducks_register_query_stream_surfaces(duckdb_connection con, rducks_runtime_entry_t *runtime) {
    duckdb_scalar_function open_fn = NULL;
    duckdb_scalar_function schema_fn = NULL;
    duckdb_scalar_function next_fn = NULL;
    duckdb_scalar_function close_fn = NULL;
    duckdb_logical_type varchar_type = NULL;
    duckdb_logical_type bool_type = NULL;
    bool ok = false;

    open_fn = duckdb_create_scalar_function();
    schema_fn = duckdb_create_scalar_function();
    next_fn = duckdb_create_scalar_function();
    close_fn = duckdb_create_scalar_function();
    varchar_type = duckdb_create_logical_type(DUCKDB_TYPE_VARCHAR);
    bool_type = duckdb_create_logical_type(DUCKDB_TYPE_BOOLEAN);
    if (!open_fn || !schema_fn || !next_fn || !close_fn || !varchar_type || !bool_type) goto cleanup;

    duckdb_scalar_function_set_name(open_fn, "rducks_query_stream_open");
    duckdb_scalar_function_add_parameter(open_fn, varchar_type);
    duckdb_scalar_function_set_return_type(open_fn, varchar_type);
    duckdb_scalar_function_set_volatile(open_fn);
    duckdb_scalar_function_set_extra_info(open_fn, runtime, NULL);
    duckdb_scalar_function_set_function(open_fn, rducks_query_stream_open_scalar);
    if (duckdb_register_scalar_function(con, open_fn) != DuckDBSuccess) goto cleanup;

    duckdb_scalar_function_set_name(schema_fn, "rducks_query_stream_schema");
    duckdb_scalar_function_add_parameter(schema_fn, varchar_type);
    duckdb_scalar_function_set_return_type(schema_fn, bool_type);
    duckdb_scalar_function_set_volatile(schema_fn);
    duckdb_scalar_function_set_extra_info(schema_fn, runtime, NULL);
    duckdb_scalar_function_set_function(schema_fn, rducks_query_stream_schema_scalar);
    if (duckdb_register_scalar_function(con, schema_fn) != DuckDBSuccess) goto cleanup;

    duckdb_scalar_function_set_name(next_fn, "rducks_query_stream_next");
    duckdb_scalar_function_add_parameter(next_fn, varchar_type);
    duckdb_scalar_function_set_return_type(next_fn, bool_type);
    duckdb_scalar_function_set_volatile(next_fn);
    duckdb_scalar_function_set_extra_info(next_fn, runtime, NULL);
    duckdb_scalar_function_set_function(next_fn, rducks_query_stream_next_scalar);
    if (duckdb_register_scalar_function(con, next_fn) != DuckDBSuccess) goto cleanup;

    duckdb_scalar_function_set_name(close_fn, "rducks_query_stream_close");
    duckdb_scalar_function_add_parameter(close_fn, varchar_type);
    duckdb_scalar_function_set_return_type(close_fn, bool_type);
    duckdb_scalar_function_set_volatile(close_fn);
    duckdb_scalar_function_set_extra_info(close_fn, runtime, NULL);
    duckdb_scalar_function_set_function(close_fn, rducks_query_stream_close_scalar);
    if (duckdb_register_scalar_function(con, close_fn) != DuckDBSuccess) goto cleanup;

    ok = true;
cleanup:
    if (open_fn) duckdb_destroy_scalar_function(&open_fn);
    if (schema_fn) duckdb_destroy_scalar_function(&schema_fn);
    if (next_fn) duckdb_destroy_scalar_function(&next_fn);
    if (close_fn) duckdb_destroy_scalar_function(&close_fn);
    if (varchar_type) duckdb_destroy_logical_type(&varchar_type);
    if (bool_type) duckdb_destroy_logical_type(&bool_type);
    return ok;
}

static bool rducks_register_version(duckdb_connection con) {
    return rducks_register_noarg_scalar(con, "rducks_version", DUCKDB_TYPE_VARCHAR, rducks_version_scalar, false);
}

static int rducks_runtime_refresh_connection(rducks_runtime_entry_t *runtime, duckdb_database database,
                                             char *err, size_t err_cap) {
    duckdb_connection old_connection = NULL;
    duckdb_connection old_stream_connection = NULL;
    duckdb_connection new_connection = NULL;
    duckdb_connection new_stream_connection = NULL;
    if (!runtime || !database) {
        snprintf(err, err_cap, "Rducks runtime refresh is missing database state");
        return 0;
    }
    if (duckdb_connect(database, &new_connection) == DuckDBError || !new_connection) {
        rducks_runtime_lock();
        g_runtime_connection_open_failed++;
        rducks_runtime_unlock();
        snprintf(err, err_cap, "failed to reopen Rducks extension connection");
        return 0;
    }
    rducks_runtime_lock();
    g_runtime_connections_opened++;
    rducks_runtime_unlock();
    if (!rducks_runtime_configure_connection(new_connection, err, err_cap)) {
        duckdb_disconnect(&new_connection);
        rducks_runtime_lock();
        g_runtime_connections_closed++;
        rducks_runtime_unlock();
        return 0;
    }
    if (duckdb_connect(database, &new_stream_connection) == DuckDBError || !new_stream_connection) {
        duckdb_disconnect(&new_connection);
        rducks_runtime_lock();
        g_runtime_connection_open_failed++;
        g_runtime_connections_closed++;
        rducks_runtime_unlock();
        snprintf(err, err_cap, "failed to reopen Rducks query stream connection");
        return 0;
    }
    rducks_runtime_lock();
    g_runtime_connections_opened++;
    rducks_runtime_unlock();
    if (!rducks_runtime_configure_connection(new_stream_connection, err, err_cap)) {
        duckdb_disconnect(&new_stream_connection);
        duckdb_disconnect(&new_connection);
        rducks_runtime_lock();
        g_runtime_connections_closed += 2;
        rducks_runtime_unlock();
        return 0;
    }
    rducks_query_stream_close_all(runtime);
    rducks_runtime_forget_udf_registry(runtime);
    rducks_runtime_lock();
    old_connection = runtime->connection;
    old_stream_connection = runtime->query_stream_connection;
    runtime->database = database;
    runtime->connection = new_connection;
    runtime->query_stream_connection = new_stream_connection;
    runtime->query_stream_connection_busy = 0;
    runtime->registration_surface_ready = 0;
    rducks_runtime_unlock();
    if (old_connection) {
        duckdb_disconnect(&old_connection);
        rducks_runtime_lock();
        g_runtime_connections_closed++;
        rducks_runtime_unlock();
    }
    if (old_stream_connection) {
        duckdb_disconnect(&old_stream_connection);
        rducks_runtime_lock();
        g_runtime_connections_closed++;
        rducks_runtime_unlock();
    }
    return 1;
}

DUCKDB_EXTENSION_ENTRYPOINT(duckdb_connection connection,
                            duckdb_extension_info info,
                            struct duckdb_extension_access *access) {
    duckdb_database database = NULL;
    rducks_runtime_entry_t *runtime = NULL;
    char err[256];
    err[0] = '\0';

    if (access && info) {
        duckdb_database *db_ptr = access->get_database(info);
        if (db_ptr) {
            database = *db_ptr;
        }
    }
    runtime = rducks_runtime_get_or_create(database, connection, err, sizeof(err));
    if (!runtime) {
        if (access) {
            access->set_error(info, err[0] ? err : "failed to initialize Rducks runtime");
        }
        return false;
    }

    rducks_runtime_lock();
    int ready = runtime->registration_surface_ready;
    rducks_runtime_unlock();
    if (!rducks_registration_surface_available(connection)) {
        if (ready && !rducks_runtime_refresh_connection(runtime, database, err, sizeof(err))) {
            if (access) {
                access->set_error(info, err[0] ? err : "failed to refresh Rducks runtime connection");
            }
            return false;
        }
        if (!rducks_register_version(connection) || !rducks_register_runtime_token(connection, runtime) ||
            !rducks_register_queue_stats(connection, runtime) ||
            !rducks_register_dev_diagnostic_surfaces(connection, runtime) ||
            !rducks_register_main_thread_token_surface(connection, runtime) ||
            !rducks_register_execution_backend_surface(connection, runtime) || !rducks_register_udf_stat_surface(connection, runtime) ||
            !rducks_register_scalar_surface(connection, runtime) || !rducks_register_table_surface(connection, runtime) ||
            !rducks_register_aggregate_surface(connection, runtime) || !rducks_register_query_stream_surfaces(connection, runtime)) {
            if (access) {
                access->set_error(info, "failed to register Rducks SQL surface");
            }
            return false;
        }
    }
    rducks_runtime_lock();
    runtime->registration_surface_ready = 1;
    rducks_runtime_unlock();
    return true;
}
