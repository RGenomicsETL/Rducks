/* Included by ../rducks_extension.c. */

static int rducks_is_main_thread(rducks_runtime_entry_t *runtime) {
    return rducks_is_recorded_main_thread(runtime);
}

static int rducks_allow_calling_thread_r_execution(rducks_runtime_entry_t *runtime, char *err, size_t err_cap) {
    if (!runtime || !rducks_is_main_thread(runtime)) {
        snprintf(err, err_cap, "Rducks R execution reached a non-calling DuckDB execution thread");
        return 0;
    }
    return 1;
}

static int rducks_set_execution_backend(rducks_runtime_entry_t *runtime, const char *backend,
                                        char *err, size_t err_cap) {
    if (!runtime) {
        snprintf(err, err_cap, "Rducks runtime is not initialized for this DuckDB connection");
        return 0;
    }
    if (!backend || !backend[0] || strcmp(backend, "single") == 0) {
        rducks_runtime_lock();
        runtime->execution_backend = RDUCKS_BACKEND_SINGLE;
        rducks_runtime_unlock();
        return 1;
    }
    if (strcmp(backend, "concurrent_inproc") == 0) {
        rducks_runtime_lock();
        runtime->execution_backend = RDUCKS_BACKEND_CONCURRENT_INPROC;
        rducks_runtime_unlock();
        return 1;
    }
    if (strcmp(backend, "multiprocess_parallel") == 0) {
        rducks_runtime_lock();
        runtime->execution_backend = RDUCKS_BACKEND_MULTIPROCESS_PARALLEL;
        rducks_runtime_unlock();
        return 1;
    }
    snprintf(err, err_cap, "unsupported Rducks execution backend: %s", backend);
    return 0;
}

static rducks_execution_backend_t rducks_get_execution_backend(rducks_runtime_entry_t *runtime) {
    rducks_execution_backend_t backend = RDUCKS_BACKEND_SINGLE;
    if (!runtime) return backend;
    rducks_runtime_lock();
    backend = runtime->execution_backend;
    rducks_runtime_unlock();
    return backend;
}

static int rducks_concurrent_inproc_enabled(rducks_runtime_entry_t *runtime) {
    return rducks_get_execution_backend(runtime) == RDUCKS_BACKEND_CONCURRENT_INPROC;
}

static int rducks_multiprocess_parallel_enabled(rducks_runtime_entry_t *runtime) {
    return rducks_get_execution_backend(runtime) == RDUCKS_BACKEND_MULTIPROCESS_PARALLEL;
}

static rducks_r_scalar_meta_t *rducks_runtime_find_udf_locked(rducks_runtime_entry_t *runtime, const char *name) {
    rducks_r_scalar_meta_t *cur;
    if (!runtime || !name) return NULL;
    cur = runtime->udf_registry_head;
    while (cur) {
        if (cur->name && strcmp(cur->name, name) == 0) return cur;
        cur = cur->registry_next;
    }
    return NULL;
}

static void rducks_runtime_register_udf(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta) {
    if (!runtime || !meta || !meta->name) return;
    rducks_runtime_lock();
    meta->registry_next = runtime->udf_registry_head;
    runtime->udf_registry_head = meta;
    rducks_runtime_unlock();
}

static void rducks_runtime_unregister_udf(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta) {
    rducks_r_scalar_meta_t *prev = NULL;
    rducks_r_scalar_meta_t *cur;
    if (!runtime || !meta) return;
    rducks_runtime_lock();
    cur = runtime->udf_registry_head;
    while (cur) {
        if (cur == meta) {
            if (prev) {
                prev->registry_next = cur->registry_next;
            } else {
                runtime->udf_registry_head = cur->registry_next;
            }
            cur->registry_next = NULL;
            break;
        }
        prev = cur;
        cur = cur->registry_next;
    }
    rducks_runtime_unlock();
}

typedef struct rducks_preserved_release_node {
    SEXP object;
    struct rducks_preserved_release_node *next;
} rducks_preserved_release_node_t;

static rducks_preserved_release_node_t *g_preserved_release_head = NULL;
static rducks_preserved_release_node_t *g_preserved_release_tail = NULL;
static uint64_t g_preserved_release_queued = 0;
static uint64_t g_preserved_release_released = 0;
static uint64_t g_preserved_release_failed = 0;

static void rducks_preserved_release_record_released(uint64_t count) {
    if (count == 0U) return;
    rducks_runtime_lock();
    g_preserved_release_released += count;
    rducks_runtime_unlock();
}

static void rducks_preserved_release_now(SEXP object) {
    if (!object || object == R_NilValue) return;
    R_ReleaseObject(object);
    rducks_preserved_release_record_released(1U);
}

static void rducks_preserved_release_enqueue(SEXP object) {
    rducks_preserved_release_node_t *node;
    if (!object || object == R_NilValue) return;
    node = (rducks_preserved_release_node_t *)malloc(sizeof(*node));
    if (!node) {
        /* Leaking a preserved object is safer than calling R_ReleaseObject()
         * from an arbitrary DuckDB destructor thread.
         */
        rducks_runtime_lock();
        g_preserved_release_failed++;
        rducks_runtime_unlock();
        return;
    }
    node->object = object;
    node->next = NULL;
    rducks_runtime_lock();
    if (g_preserved_release_tail) {
        g_preserved_release_tail->next = node;
    } else {
        g_preserved_release_head = node;
    }
    g_preserved_release_tail = node;
    g_preserved_release_queued++;
    rducks_runtime_unlock();
}

static uint64_t rducks_preserved_release_drain_on_main(rducks_runtime_entry_t *runtime) {
    rducks_preserved_release_node_t *node;
    uint64_t released = 0;
    if (!runtime || !rducks_is_main_thread(runtime)) return 0;
    rducks_runtime_lock();
    node = g_preserved_release_head;
    g_preserved_release_head = NULL;
    g_preserved_release_tail = NULL;
    rducks_runtime_unlock();
    while (node) {
        rducks_preserved_release_node_t *next = node->next;
        if (node->object && node->object != R_NilValue) {
            R_ReleaseObject(node->object);
            released++;
        }
        free(node);
        node = next;
    }
    rducks_preserved_release_record_released(released);
    return released;
}

static void rducks_preserved_release_snapshot(uint64_t *queued, uint64_t *released,
                                              uint64_t *failed, uint64_t *pending) {
    uint64_t pending_count = 0;
    rducks_preserved_release_node_t *node;
    rducks_runtime_lock();
    for (node = g_preserved_release_head; node; node = node->next) {
        pending_count++;
    }
    if (queued) *queued = g_preserved_release_queued;
    if (released) *released = g_preserved_release_released;
    if (failed) *failed = g_preserved_release_failed;
    if (pending) *pending = pending_count;
    rducks_runtime_unlock();
}

static void rducks_runtime_forget_udf_registry(rducks_runtime_entry_t *runtime) {
    /* Used when a DuckDB extension reload invalidates catalog-owned function
     * metadata. Detach registry bookkeeping without calling R API. If DuckDB
     * later destroys those metadata objects off-main, their preserved R
     * evaluators are queued for a safe recorded-main-thread release. Runtime
     * entries are retained for the process lifetime, so keep meta->runtime
     * stable instead of racing a destructor/callback read with a NULL write.
     * Native RIPC client pools are not R objects; close them here so forgotten
     * metas cannot strand NNG sockets outside the runtime quiesce path.
     */
    rducks_r_scalar_meta_t *cur;
    rducks_r_scalar_meta_t *detached;
    if (!runtime) return;
    rducks_runtime_lock();
    detached = runtime->udf_registry_head;
    runtime->udf_registry_head = NULL;
    rducks_runtime_unlock();
    for (cur = detached; cur; ) {
        rducks_r_scalar_meta_t *next = cur->registry_next;
        cur->registry_next = NULL;
        rducks_nng_client_pool_destroy(&cur->ripc_client_pool);
        cur = next;
    }
}

static uint64_t rducks_udf_counter_load(atomic_uint_fast64_t *counter) {
    return (uint64_t)atomic_load_explicit(counter, memory_order_relaxed);
}

static void rducks_udf_counter_store(atomic_uint_fast64_t *counter, uint64_t value) {
    atomic_store_explicit(counter, (uint_fast64_t)value, memory_order_relaxed);
}

static uint64_t rducks_udf_counter_add(atomic_uint_fast64_t *counter, uint64_t value) {
    return (uint64_t)(atomic_fetch_add_explicit(counter, (uint_fast64_t)value,
                                               memory_order_relaxed) + (uint_fast64_t)value);
}

static void rducks_udf_counter_sub_saturating(atomic_uint_fast64_t *counter, uint64_t value) {
    uint_fast64_t cur;
    uint_fast64_t next;
    if (value == 0U) return;
    cur = atomic_load_explicit(counter, memory_order_relaxed);
    do {
        next = cur > (uint_fast64_t)value ? cur - (uint_fast64_t)value : 0U;
    } while (!atomic_compare_exchange_weak_explicit(counter, &cur, next,
                                                    memory_order_relaxed,
                                                    memory_order_relaxed));
}

static void rducks_udf_counter_max(atomic_uint_fast64_t *counter, uint64_t value) {
    uint_fast64_t cur = atomic_load_explicit(counter, memory_order_relaxed);
    while (cur < (uint_fast64_t)value &&
           !atomic_compare_exchange_weak_explicit(counter, &cur, (uint_fast64_t)value,
                                                  memory_order_relaxed,
                                                  memory_order_relaxed)) {
    }
}

static void rducks_udf_stats_init(rducks_r_scalar_meta_t *meta) {
    if (!meta) return;
    atomic_init(&meta->dispatch_chunks, 0U);
    atomic_init(&meta->dispatch_rows, 0U);
    atomic_init(&meta->direct_chunks, 0U);
    atomic_init(&meta->queued_chunks, 0U);
    atomic_init(&meta->queue_pending_current, 0U);
    atomic_init(&meta->queue_pending_max, 0U);
    atomic_init(&meta->arrow_r_chunks, 0U);
    atomic_init(&meta->arrow_c_chunks, 0U);
    atomic_init(&meta->arrow_c_input_snapshot_chunks, 0U);
    atomic_init(&meta->arrow_c_owned_result_chunk_chunks, 0U);
    atomic_init(&meta->arrow_ipc_chunks, 0U);
    atomic_init(&meta->ripc_collect_batches, 0U);
    atomic_init(&meta->ripc_collect_requests, 0U);
    atomic_init(&meta->ripc_collect_max_batch, 0U);
    atomic_init(&meta->ripc_submit_wave_max, 0U);
    atomic_init(&meta->ripc_collect_ready_max, 0U);
    atomic_init(&meta->ripc_inflight_current, 0U);
    atomic_init(&meta->ripc_inflight_max, 0U);
}

static void rducks_udf_record_dispatch(rducks_r_scalar_meta_t *meta, idx_t rows, int queued) {
    if (!meta || !meta->runtime) return;
    rducks_udf_counter_add(&meta->dispatch_chunks, 1U);
    rducks_udf_counter_add(&meta->dispatch_rows, (uint64_t)rows);
    if (queued) {
        rducks_udf_counter_add(&meta->queued_chunks, 1U);
    } else {
        rducks_udf_counter_add(&meta->direct_chunks, 1U);
    }
}

static void rducks_udf_record_evaluator(rducks_r_scalar_meta_t *meta, idx_t rows) {
    (void)rows;
    if (!meta || !meta->runtime) return;
    if (meta->eval_mode == RDUCKS_EVAL_R) {
        rducks_udf_counter_add(&meta->arrow_r_chunks, 1U);
    } else if (meta->eval_mode == RDUCKS_EVAL_RIPC) {
        rducks_udf_counter_add(&meta->arrow_ipc_chunks, 1U);
    } else {
        rducks_udf_counter_add(&meta->arrow_c_chunks, 1U);
    }
}

static void rducks_udf_record_arrow_c_input_snapshot(rducks_r_scalar_meta_t *meta) {
    if (!meta || !meta->runtime) return;
    if (meta->eval_mode != RDUCKS_EVAL_RC && meta->eval_mode != RDUCKS_EVAL_RCV) return;
    rducks_udf_counter_add(&meta->arrow_c_input_snapshot_chunks, 1U);
}

static void rducks_udf_record_arrow_c_owned_result_chunk(rducks_r_scalar_meta_t *meta) {
    if (!meta || !meta->runtime) return;
    if (meta->eval_mode != RDUCKS_EVAL_RC && meta->eval_mode != RDUCKS_EVAL_RCV) return;
    rducks_udf_counter_add(&meta->arrow_c_owned_result_chunk_chunks, 1U);
}

static void rducks_udf_record_queue_pending_add(rducks_r_scalar_meta_t *meta) {
    uint64_t current;
    if (!meta || !meta->runtime) return;
    current = rducks_udf_counter_add(&meta->queue_pending_current, 1U);
    rducks_udf_counter_max(&meta->queue_pending_max, current);
}

static void rducks_udf_record_queue_pending_done(rducks_r_scalar_meta_t *meta) {
    if (!meta || !meta->runtime) return;
    rducks_udf_counter_sub_saturating(&meta->queue_pending_current, 1U);
}

static void rducks_udf_record_ripc_inflight_add(rducks_r_scalar_meta_t *meta) {
    uint64_t current;
    if (!meta || !meta->runtime || meta->eval_mode != RDUCKS_EVAL_RIPC) return;
    current = rducks_udf_counter_add(&meta->ripc_inflight_current, 1U);
    rducks_udf_counter_max(&meta->ripc_inflight_max, current);
}

static void rducks_udf_record_ripc_inflight_done(rducks_r_scalar_meta_t *meta, size_t count) {
    if (!meta || !meta->runtime || meta->eval_mode != RDUCKS_EVAL_RIPC || count == 0U) return;
    rducks_udf_counter_sub_saturating(&meta->ripc_inflight_current, (uint64_t)count);
}

static void rducks_udf_record_ripc_batch(rducks_r_scalar_meta_t *meta, size_t batch_size) {
    if (!meta || !meta->runtime || meta->eval_mode != RDUCKS_EVAL_RIPC || batch_size == 0U) return;
    rducks_udf_counter_add(&meta->ripc_collect_batches, 1U);
    rducks_udf_counter_add(&meta->ripc_collect_requests, (uint64_t)batch_size);
    rducks_udf_counter_max(&meta->ripc_collect_max_batch, (uint64_t)batch_size);
}

static void rducks_udf_record_ripc_submit_wave(rducks_r_scalar_meta_t *meta, size_t wave_size) {
    if (!meta || !meta->runtime || meta->eval_mode != RDUCKS_EVAL_RIPC || wave_size == 0U) return;
    rducks_udf_counter_max(&meta->ripc_submit_wave_max, (uint64_t)wave_size);
}

static void rducks_udf_record_ripc_collect_ready(rducks_r_scalar_meta_t *meta, size_t ready_size) {
    if (!meta || !meta->runtime || meta->eval_mode != RDUCKS_EVAL_RIPC || ready_size == 0U) return;
    rducks_udf_counter_max(&meta->ripc_collect_ready_max, (uint64_t)ready_size);
}

static const char *rducks_udf_stat_fields_text(void) {
    return "name\n"
           "eval_mode\n"
           "marshalling\n"
           "dispatch_chunks\n"
           "dispatch_rows\n"
           "direct_chunks\n"
           "queued_chunks\n"
           "queue_pending_current\n"
           "queue_pending_max\n"
           "arrow_r_chunks\n"
           "arrow_c_chunks\n"
           "arrow_c_input_snapshot_chunks\n"
           "arrow_c_owned_result_chunk_chunks\n"
           "arrow_ipc_chunks\n"
           "ripc_collect_batches\n"
           "ripc_collect_requests\n"
           "ripc_collect_max_batch\n"
           "ripc_submit_wave_max\n"
           "ripc_collect_ready_max\n"
           "ripc_inflight_current\n"
           "ripc_inflight_max";
}

typedef struct rducks_udf_counter_stat {
    const char *name;
    size_t offset;
} rducks_udf_counter_stat_t;

#define RDUCKS_UDF_COUNTER_STAT(name, member) { name, offsetof(rducks_r_scalar_meta_t, member) }

static const rducks_udf_counter_stat_t rducks_udf_counter_stats[] = {
    RDUCKS_UDF_COUNTER_STAT("dispatch_chunks", dispatch_chunks),
    RDUCKS_UDF_COUNTER_STAT("dispatch_rows", dispatch_rows),
    RDUCKS_UDF_COUNTER_STAT("direct_chunks", direct_chunks),
    RDUCKS_UDF_COUNTER_STAT("queued_chunks", queued_chunks),
    RDUCKS_UDF_COUNTER_STAT("queue_pending_current", queue_pending_current),
    RDUCKS_UDF_COUNTER_STAT("queue_pending_max", queue_pending_max),
    RDUCKS_UDF_COUNTER_STAT("arrow_r_chunks", arrow_r_chunks),
    RDUCKS_UDF_COUNTER_STAT("arrow_c_chunks", arrow_c_chunks),
    RDUCKS_UDF_COUNTER_STAT("arrow_c_input_snapshot_chunks", arrow_c_input_snapshot_chunks),
    RDUCKS_UDF_COUNTER_STAT("arrow_c_owned_result_chunk_chunks", arrow_c_owned_result_chunk_chunks),
    RDUCKS_UDF_COUNTER_STAT("arrow_ipc_chunks", arrow_ipc_chunks),
    RDUCKS_UDF_COUNTER_STAT("ripc_collect_batches", ripc_collect_batches),
    RDUCKS_UDF_COUNTER_STAT("ripc_collect_requests", ripc_collect_requests),
    RDUCKS_UDF_COUNTER_STAT("ripc_collect_max_batch", ripc_collect_max_batch),
    RDUCKS_UDF_COUNTER_STAT("ripc_submit_wave_max", ripc_submit_wave_max),
    RDUCKS_UDF_COUNTER_STAT("ripc_collect_ready_max", ripc_collect_ready_max),
    RDUCKS_UDF_COUNTER_STAT("ripc_inflight_current", ripc_inflight_current),
    RDUCKS_UDF_COUNTER_STAT("ripc_inflight_max", ripc_inflight_max)
};

#undef RDUCKS_UDF_COUNTER_STAT

static atomic_uint_fast64_t *rducks_udf_counter_stat_ptr(rducks_r_scalar_meta_t *meta,
                                                         const rducks_udf_counter_stat_t *stat) {
    return (atomic_uint_fast64_t *)((char *)meta + stat->offset);
}

static int rducks_runtime_format_counter_stat(rducks_r_scalar_meta_t *meta, const char *field,
                                              char *out, size_t out_cap) {
    size_t n = sizeof(rducks_udf_counter_stats) / sizeof(rducks_udf_counter_stats[0]);
    for (size_t i = 0U; i < n; i++) {
        if (strcmp(field, rducks_udf_counter_stats[i].name) == 0) {
            snprintf(out, out_cap, "%llu",
                     (unsigned long long)rducks_udf_counter_load(
                         rducks_udf_counter_stat_ptr(meta, &rducks_udf_counter_stats[i])));
            return 1;
        }
    }
    return 0;
}

static void rducks_runtime_reset_udf_stats_locked(rducks_r_scalar_meta_t *meta) {
    if (!meta) return;
    rducks_udf_counter_store(&meta->dispatch_chunks, 0U);
    rducks_udf_counter_store(&meta->dispatch_rows, 0U);
    rducks_udf_counter_store(&meta->direct_chunks, 0U);
    rducks_udf_counter_store(&meta->queued_chunks, 0U);
    rducks_udf_counter_store(&meta->arrow_r_chunks, 0U);
    rducks_udf_counter_store(&meta->arrow_c_chunks, 0U);
    rducks_udf_counter_store(&meta->arrow_c_input_snapshot_chunks, 0U);
    rducks_udf_counter_store(&meta->arrow_c_owned_result_chunk_chunks, 0U);
    rducks_udf_counter_store(&meta->arrow_ipc_chunks, 0U);
    rducks_udf_counter_store(&meta->ripc_collect_batches, 0U);
    rducks_udf_counter_store(&meta->ripc_collect_requests, 0U);
    rducks_udf_counter_store(&meta->ripc_collect_max_batch, 0U);
    rducks_udf_counter_store(&meta->ripc_submit_wave_max, 0U);
    rducks_udf_counter_store(&meta->ripc_collect_ready_max, 0U);
    rducks_udf_counter_store(&meta->queue_pending_max,
                             rducks_udf_counter_load(&meta->queue_pending_current));
    rducks_udf_counter_store(&meta->ripc_inflight_max,
                             rducks_udf_counter_load(&meta->ripc_inflight_current));
}

static int rducks_runtime_reset_udf_stats(rducks_runtime_entry_t *runtime, const char *name,
                                          char *err, size_t err_cap) {
    rducks_r_scalar_meta_t *meta;
    int reset_any = 0;
    if (!runtime || !name) {
        snprintf(err, err_cap, "invalid Rducks UDF stat reset request");
        return 0;
    }
    rducks_runtime_lock();
    if (!name[0]) {
        for (meta = runtime->udf_registry_head; meta; meta = meta->registry_next) {
            rducks_runtime_reset_udf_stats_locked(meta);
            reset_any = 1;
        }
    } else {
        meta = rducks_runtime_find_udf_locked(runtime, name);
        if (meta) {
            rducks_runtime_reset_udf_stats_locked(meta);
            reset_any = 1;
        }
    }
    rducks_runtime_unlock();
    if (!reset_any && name[0]) {
        snprintf(err, err_cap, "unknown Rducks UDF: %s", name);
        return 0;
    }
    return 1;
}

static int rducks_runtime_udf_stat(rducks_runtime_entry_t *runtime, const char *name, const char *field,
                                   char *out, size_t out_cap, char *err, size_t err_cap) {
    rducks_r_scalar_meta_t *meta;
    int ok = 1;
    if (!out || out_cap == 0U) return 0;
    out[0] = '\0';
    rducks_preserved_release_drain_on_main(runtime);
    if (!runtime || !name || !name[0] || !field || !field[0]) {
        snprintf(err, err_cap, "invalid Rducks UDF stat request");
        return 0;
    }

    rducks_runtime_lock();
    meta = rducks_runtime_find_udf_locked(runtime, name);
    if (!meta) {
        rducks_runtime_unlock();
        snprintf(err, err_cap, "unknown Rducks UDF: %s", name);
        return 0;
    }

    if (strcmp(field, "name") == 0) {
        snprintf(out, out_cap, "%s", meta->name ? meta->name : "");
    } else if (strcmp(field, "eval_mode") == 0) {
        snprintf(out, out_cap, "%s", meta->eval_mode == RDUCKS_EVAL_R ? "R" :
                 (meta->eval_mode == RDUCKS_EVAL_RIPC ? "RIPC" :
                  (meta->eval_mode == RDUCKS_EVAL_RCV ? "RCV" : "RC")));
    } else if (strcmp(field, "marshalling") == 0) {
        snprintf(out, out_cap, "%s", meta->eval_mode == RDUCKS_EVAL_R ? "arrow_r" :
                 (meta->eval_mode == RDUCKS_EVAL_RIPC ? "arrow_ipc" : "arrow_c"));
    } else if (!rducks_runtime_format_counter_stat(meta, field, out, out_cap)) {
        ok = 0;
    }
    rducks_runtime_unlock();

    if (!ok) {
        snprintf(err, err_cap, "unknown Rducks UDF stat field: %s", field);
    }
    return ok;
}

static void rducks_r_scalar_bind_state_destroy(void *ptr) {
    rducks_r_scalar_bind_state_t *state = (rducks_r_scalar_bind_state_t *)ptr;
    if (!state) return;
    rducks_type_desc_array_destroy(state->args, state->arity);
    free(state);
}

static void *rducks_r_scalar_bind_state_copy(void *ptr) {
    rducks_r_scalar_bind_state_t *src = (rducks_r_scalar_bind_state_t *)ptr;
    rducks_r_scalar_bind_state_t *dst;
    if (!src) return NULL;
    dst = (rducks_r_scalar_bind_state_t *)rducks_calloc_array(1, sizeof(*dst));
    if (!dst) return NULL;
    dst->runtime = src->runtime;
    dst->connection_id = src->connection_id;
    dst->arity = src->arity;
    if (src->arity) {
        dst->args = rducks_type_desc_array_clone(src->args, src->arity);
        if (!dst->args) {
            free(dst);
            return NULL;
        }
    }
    return dst;
}

static void rducks_r_scalar_local_state_destroy(void *ptr) {
    rducks_r_scalar_local_state_t *state = (rducks_r_scalar_local_state_t *)ptr;
    if (!state) return;
    rducks_type_desc_array_destroy(state->args, state->arity);
    free(state);
}

static idx_t rducks_client_context_connection_id(duckdb_client_context context) {
    if (!context) return 0;
    return duckdb_client_context_get_connection_id(context);
}

static int rducks_r_scalar_resolve_dynamic_bind_args(duckdb_bind_info info,
                                                     rducks_r_scalar_bind_state_t *state,
                                                     char *err, size_t err_cap) {
    idx_t count;
    if (!info || !state) {
        snprintf(err, err_cap, "invalid dynamic Rducks bind state");
        return 0;
    }
    count = duckdb_scalar_function_bind_get_argument_count(info);
    state->arity = (size_t)count;
    if (!count) return 1;
    if ((size_t)count > SIZE_MAX / sizeof(*state->args)) {
        snprintf(err, err_cap, "dynamic Rducks scalar UDF has too many arguments");
        return 0;
    }
    state->args = (rducks_type_desc_t **)rducks_calloc_array((size_t)count, sizeof(*state->args));
    if (!state->args) {
        snprintf(err, err_cap, "out of memory resolving dynamic Rducks arguments");
        return 0;
    }
    for (idx_t i = 0; i < count; i++) {
        duckdb_expression expr = duckdb_scalar_function_bind_get_argument(info, i);
        duckdb_logical_type logical_type = expr ? duckdb_expression_return_type(expr) : NULL;
        int ok;
        if (expr) duckdb_destroy_expression(&expr);
        if (!logical_type) {
            snprintf(err, err_cap, "failed to inspect dynamic Rducks argument %llu", (unsigned long long)(i + 1));
            return 0;
        }
        ok = rducks_type_desc_from_logical_type(logical_type, &state->args[i], err, err_cap);
        duckdb_destroy_logical_type(&logical_type);
        if (!ok) return 0;
    }
    return 1;
}

static void rducks_effective_meta_for_state(rducks_r_scalar_meta_t *meta,
                                            rducks_r_scalar_local_state_t *state,
                                            rducks_r_scalar_meta_t *effective,
                                            rducks_r_scalar_meta_t **out) {
    if (!out) return;
    *out = meta;
    if (!meta || !state || !meta->dynamic_args || !state->args) return;
    *effective = *meta;
    effective->arity = state->arity;
    effective->args = state->args;
    *out = effective;
}

static void rducks_r_scalar_bind(duckdb_bind_info info) {
    rducks_r_scalar_meta_t *meta;
    rducks_r_scalar_bind_state_t *state;
    duckdb_client_context context = NULL;

    if (!info) return;
    meta = (rducks_r_scalar_meta_t *)duckdb_scalar_function_bind_get_extra_info(info);
    if (!meta || !meta->runtime) {
        duckdb_scalar_function_bind_set_error(info, "Rducks scalar metadata is missing runtime state");
        return;
    }

    state = (rducks_r_scalar_bind_state_t *)rducks_calloc_array(1, sizeof(*state));
    if (!state) {
        duckdb_scalar_function_bind_set_error(info, "out of memory allocating Rducks bind state");
        return;
    }
    state->runtime = meta->runtime;

    duckdb_scalar_function_get_client_context(info, &context);
    if (context) {
        state->connection_id = rducks_client_context_connection_id(context);
        duckdb_destroy_client_context(&context);
    }

    if (meta->dynamic_args) {
        char err_msg[256];
        err_msg[0] = '\0';
        if (!rducks_r_scalar_resolve_dynamic_bind_args(info, state, err_msg, sizeof(err_msg))) {
            rducks_r_scalar_bind_state_destroy(state);
            duckdb_scalar_function_bind_set_error(info, err_msg[0] ? err_msg : "failed to resolve dynamic Rducks argument types");
            return;
        }
    }

    duckdb_scalar_function_set_bind_data(info, state, rducks_r_scalar_bind_state_destroy);
    duckdb_scalar_function_set_bind_data_copy(info, rducks_r_scalar_bind_state_copy);
}

static void rducks_r_scalar_init(duckdb_init_info info) {
    rducks_r_scalar_meta_t *meta;
    rducks_r_scalar_bind_state_t *bind_state;
    rducks_r_scalar_local_state_t *state;
    duckdb_client_context context = NULL;

    if (!info) return;
    meta = (rducks_r_scalar_meta_t *)duckdb_scalar_function_init_get_extra_info(info);
    bind_state = (rducks_r_scalar_bind_state_t *)duckdb_scalar_function_init_get_bind_data(info);

    state = (rducks_r_scalar_local_state_t *)rducks_calloc_array(1, sizeof(*state));
    if (!state) {
        duckdb_scalar_function_init_set_error(info, "out of memory allocating Rducks worker-local state");
        return;
    }
    state->runtime = bind_state && bind_state->runtime ? bind_state->runtime : (meta ? meta->runtime : NULL);
    if (!state->runtime) {
        free(state);
        duckdb_scalar_function_init_set_error(info, "Rducks scalar worker-local state is missing runtime state");
        return;
    }
    state->connection_id = bind_state ? bind_state->connection_id : 0;

    duckdb_scalar_function_init_get_client_context(info, &context);
    if (context) {
        state->connection_id = rducks_client_context_connection_id(context);
        duckdb_destroy_client_context(&context);
    }
    if (bind_state && bind_state->arity) {
        state->arity = bind_state->arity;
        state->args = rducks_type_desc_array_clone(bind_state->args, bind_state->arity);
        if (!state->args) {
            free(state);
            duckdb_scalar_function_init_set_error(info, "out of memory copying dynamic Rducks argument types");
            return;
        }
    }
    duckdb_scalar_function_init_set_state(info, state, rducks_r_scalar_local_state_destroy);
}

static rducks_runtime_entry_t *rducks_runtime_from_function_info(duckdb_function_info info,
                                                                rducks_r_scalar_meta_t *meta) {
    rducks_r_scalar_local_state_t *state = NULL;
    if (info) {
        state = (rducks_r_scalar_local_state_t *)duckdb_scalar_function_get_state(info);
        if (state && state->runtime) return state->runtime;
    }
    return meta ? meta->runtime : NULL;
}

static void rducks_r_scalar_meta_destroy(void *ptr) {
    rducks_r_scalar_meta_t *meta = (rducks_r_scalar_meta_t *)ptr;
    if (!meta) {
        return;
    }
    rducks_runtime_unregister_udf(meta->runtime, meta);
    if (meta->fun && meta->fun != R_NilValue) {
        if (rducks_is_main_thread(meta->runtime)) {
            rducks_preserved_release_now(meta->fun);
        } else {
            rducks_preserved_release_enqueue(meta->fun);
        }
        meta->fun = R_NilValue;
    }
    free(meta->name);
    rducks_nng_client_pool_destroy(&meta->ripc_client_pool);
    if (meta->ripc_endpoints) {
        for (size_t i = 0; i < meta->ripc_endpoint_count; i++) free(meta->ripc_endpoints[i]);
    }
    free(meta->ripc_endpoints);
    free(meta->ripc_udf_id);
    if (meta->args) {
        for (size_t i = 0; i < meta->arity; i++) rducks_type_desc_destroy(meta->args[i]);
    }
    free(meta->args);
    rducks_type_desc_destroy(meta->return_desc);
    free(meta);
}
