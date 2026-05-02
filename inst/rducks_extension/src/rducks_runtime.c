/* Included by ../rducks_extension.c. */

static int rducks_is_main_thread(rducks_runtime_entry_t *runtime) {
    char current[128];
    char expected[128];
    if (!rducks_get_main_thread_token(runtime, expected, sizeof(expected))) return 0;
    rducks_current_thread_token(current, sizeof(current));
    return strcmp(current, expected) == 0;
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

static void rducks_r_scalar_bind_state_destroy(void *ptr) {
    free(ptr);
}

static void *rducks_r_scalar_bind_state_copy(void *ptr) {
    rducks_r_scalar_bind_state_t *src = (rducks_r_scalar_bind_state_t *)ptr;
    rducks_r_scalar_bind_state_t *dst;
    if (!src) return NULL;
    dst = (rducks_r_scalar_bind_state_t *)calloc(1, sizeof(*dst));
    if (!dst) return NULL;
    memcpy(dst, src, sizeof(*dst));
    return dst;
}

static void rducks_r_scalar_local_state_destroy(void *ptr) {
    free(ptr);
}

static idx_t rducks_client_context_connection_id(duckdb_client_context context) {
    if (!context) return 0;
    return duckdb_client_context_get_connection_id(context);
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

    state = (rducks_r_scalar_bind_state_t *)calloc(1, sizeof(*state));
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

    state = (rducks_r_scalar_local_state_t *)calloc(1, sizeof(*state));
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
    rducks_current_thread_token(state->worker_thread_token, sizeof(state->worker_thread_token));

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
    if (meta->fun && meta->fun != R_NilValue && rducks_is_main_thread(meta->runtime)) {
        R_ReleaseObject(meta->fun);
    }
    /* If DuckDB destroys function metadata on a worker thread, do not call into
     * R. A later main-thread release queue can make this deterministic; until
     * then a preserved-function leak is safer than off-thread R API use.
     */
    if (meta->args) {
        for (size_t i = 0; i < meta->arity; i++) rducks_type_desc_destroy(meta->args[i]);
    }
    free(meta->args);
    rducks_type_desc_destroy(meta->return_desc);
    free(meta);
}
