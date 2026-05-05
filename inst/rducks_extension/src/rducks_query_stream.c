/* Included by ../rducks_extension.c. */

/*
 * Rducks-owned streaming query surface.
 *
 * This is intentionally C API only: bind prepares the inner SQL on the
 * extension-owned connection captured from DuckDB init, function execution uses
 * duckdb_pending_prepared_streaming()/duckdb_pending_execute_task(), drains the
 * Rducks main-lane queue between pending tasks, then fetches and copies result
 * chunks to the outer table function output.
 */

typedef struct rducks_query_stream_bind {
    rducks_runtime_entry_t *runtime;
    char *sql;
} rducks_query_stream_bind_t;

typedef struct rducks_query_stream_state {
    rducks_runtime_entry_t *runtime;
    duckdb_pending_result pending;
    duckdb_result result;
    int has_pending;
    int has_result;
    int exhausted;
} rducks_query_stream_state_t;

static void rducks_query_stream_bind_destroy(void *ptr) {
    rducks_query_stream_bind_t *bind = (rducks_query_stream_bind_t *)ptr;
    if (!bind) return;
    free(bind->sql);
    free(bind);
}

static void rducks_query_stream_state_destroy(void *ptr) {
    rducks_query_stream_state_t *state = (rducks_query_stream_state_t *)ptr;
    if (!state) return;
    if (state->has_pending && state->pending) {
        duckdb_destroy_pending(&state->pending);
        state->has_pending = 0;
    }
    if (state->has_result) {
        duckdb_destroy_result(&state->result);
        state->has_result = 0;
    }
    free(state);
}

static char *rducks_copy_duckdb_alloc_string(char *value) {
    char *out;
    size_t n;
    if (!value) return NULL;
    n = strlen(value);
    out = rducks_strdup_len(value, n);
    duckdb_free(value);
    return out;
}

static void rducks_query_stream_bind(duckdb_bind_info info) {
    rducks_runtime_entry_t *runtime;
    duckdb_value value = NULL;
    char *duckdb_sql = NULL;
    char *sql = NULL;
    duckdb_prepared_statement prepared = NULL;
    rducks_query_stream_bind_t *bind = NULL;
    idx_t column_count;

    if (!info) return;
    runtime = (rducks_runtime_entry_t *)duckdb_bind_get_extra_info(info);
    if (!runtime || !runtime->connection) {
        duckdb_bind_set_error(info, "Rducks query stream runtime is not initialized");
        return;
    }
    if (duckdb_bind_get_parameter_count(info) != 1) {
        duckdb_bind_set_error(info, "rducks_query_stream() expects one SQL string argument");
        return;
    }

    value = duckdb_bind_get_parameter(info, 0);
    if (!value) {
        duckdb_bind_set_error(info, "failed to read rducks_query_stream() SQL argument");
        return;
    }
    duckdb_sql = duckdb_get_varchar(value);
    duckdb_destroy_value(&value);
    sql = rducks_copy_duckdb_alloc_string(duckdb_sql);
    if (!sql || !sql[0]) {
        free(sql);
        duckdb_bind_set_error(info, "rducks_query_stream() SQL argument must be a non-empty string");
        return;
    }

    if (duckdb_prepare(runtime->connection, sql, &prepared) == DuckDBError || !prepared) {
        const char *msg = prepared ? duckdb_prepare_error(prepared) : NULL;
        char err[512];
        snprintf(err, sizeof(err), "failed to prepare rducks_query_stream() SQL: %s", (msg && msg[0]) ? msg : "unknown error");
        if (prepared) duckdb_destroy_prepare(&prepared);
        free(sql);
        duckdb_bind_set_error(info, err);
        return;
    }

    column_count = duckdb_prepared_statement_column_count(prepared);
    for (idx_t i = 0; i < column_count; i++) {
        const char *name = duckdb_prepared_statement_column_name(prepared, i);
        duckdb_logical_type type = duckdb_prepared_statement_column_logical_type(prepared, i);
        char fallback_name[32];
        if (!type) {
            duckdb_destroy_prepare(&prepared);
            free(sql);
            duckdb_bind_set_error(info, "failed to inspect rducks_query_stream() result column type");
            return;
        }
        if (!name || !name[0]) {
            snprintf(fallback_name, sizeof(fallback_name), "col%llu", (unsigned long long)i + 1ULL);
            name = fallback_name;
        }
        duckdb_bind_add_result_column(info, name, type);
        duckdb_destroy_logical_type(&type);
    }
    duckdb_destroy_prepare(&prepared);

    bind = (rducks_query_stream_bind_t *)calloc(1, sizeof(*bind));
    if (!bind) {
        free(sql);
        duckdb_bind_set_error(info, "out of memory allocating rducks_query_stream bind data");
        return;
    }
    bind->runtime = runtime;
    bind->sql = sql;
    duckdb_bind_set_cardinality(info, 0, false);
    duckdb_bind_set_bind_data(info, bind, rducks_query_stream_bind_destroy);
}

static void rducks_query_stream_init(duckdb_init_info info) {
    rducks_query_stream_bind_t *bind;
    rducks_query_stream_state_t *state;
    duckdb_prepared_statement prepared = NULL;

    if (!info) return;
    bind = (rducks_query_stream_bind_t *)duckdb_init_get_bind_data(info);
    if (!bind || !bind->runtime || !bind->runtime->connection || !bind->sql) {
        duckdb_init_set_error(info, "rducks_query_stream bind data is missing");
        return;
    }

    state = (rducks_query_stream_state_t *)calloc(1, sizeof(*state));
    if (!state) {
        duckdb_init_set_error(info, "out of memory allocating rducks_query_stream state");
        return;
    }
    state->runtime = bind->runtime;

    if (duckdb_prepare(bind->runtime->connection, bind->sql, &prepared) == DuckDBError || !prepared) {
        const char *msg = prepared ? duckdb_prepare_error(prepared) : NULL;
        char err[512];
        snprintf(err, sizeof(err), "failed to prepare rducks_query_stream() SQL: %s", (msg && msg[0]) ? msg : "unknown error");
        if (prepared) duckdb_destroy_prepare(&prepared);
        free(state);
        duckdb_init_set_error(info, err);
        return;
    }

    if (duckdb_pending_prepared_streaming(prepared, &state->pending) == DuckDBError || !state->pending) {
        const char *msg = state->pending ? duckdb_pending_error(state->pending) : NULL;
        char err[512];
        snprintf(err, sizeof(err), "failed to create rducks_query_stream() pending result: %s", (msg && msg[0]) ? msg : "unknown error");
        if (state->pending) duckdb_destroy_pending(&state->pending);
        duckdb_destroy_prepare(&prepared);
        free(state);
        duckdb_init_set_error(info, err);
        return;
    }
    state->has_pending = 1;
    duckdb_destroy_prepare(&prepared);

    /* Outer table function execution stays single-threaded so the callback that
     * drives the inner pending query is the recorded main R lane. Inner DuckDB
     * execution may still use the runtime connection's own DuckDB task settings.
     */
    duckdb_init_set_max_threads(info, 1);
    duckdb_init_set_init_data(info, state, rducks_query_stream_state_destroy);
}

static int rducks_query_stream_drive_to_result(rducks_query_stream_state_t *state,
                                               char *err_msg, size_t err_cap) {
    duckdb_pending_state pending_state;
    if (!state || !state->runtime) {
        snprintf(err_msg, err_cap, "rducks_query_stream state is missing");
        return 0;
    }
    if (state->has_result || state->exhausted) return 1;
    if (!state->has_pending || !state->pending) {
        snprintf(err_msg, err_cap, "rducks_query_stream pending result is missing");
        return 0;
    }

    for (;;) {
        (void)rducks_queue_drain_on_main(state->runtime, 1000000);
        pending_state = duckdb_pending_execute_task(state->pending);
        if (pending_state != DUCKDB_PENDING_NO_TASKS_AVAILABLE) {
            rducks_runtime_record_pending_task(state->runtime);
        }
        (void)rducks_queue_drain_on_main(state->runtime, 1000000);

        if (pending_state == DUCKDB_PENDING_ERROR) {
            const char *msg = duckdb_pending_error(state->pending);
            snprintf(err_msg, err_cap, "rducks_query_stream pending execution failed: %s", (msg && msg[0]) ? msg : "unknown error");
            return 0;
        }
        if (pending_state == DUCKDB_PENDING_RESULT_READY) {
            if (duckdb_execute_pending(state->pending, &state->result) == DuckDBError) {
                snprintf(err_msg, err_cap, "rducks_query_stream failed to execute pending result");
                return 0;
            }
            duckdb_destroy_pending(&state->pending);
            state->has_pending = 0;
            state->has_result = 1;
            return 1;
        }
        if (pending_state == DUCKDB_PENDING_NO_TASKS_AVAILABLE) {
            pending_state = duckdb_pending_execute_check_state(state->pending);
            if (pending_state == DUCKDB_PENDING_ERROR) {
                const char *msg = duckdb_pending_error(state->pending);
                snprintf(err_msg, err_cap, "rducks_query_stream pending execution failed: %s", (msg && msg[0]) ? msg : "unknown error");
                return 0;
            }
            if (pending_state == DUCKDB_PENDING_RESULT_READY) {
                if (duckdb_execute_pending(state->pending, &state->result) == DuckDBError) {
                    snprintf(err_msg, err_cap, "rducks_query_stream failed to execute pending result");
                    return 0;
                }
                duckdb_destroy_pending(&state->pending);
                state->has_pending = 0;
                state->has_result = 1;
                return 1;
            }
            (void)rducks_queue_sleep_ms(1U);
            continue;
        }
        if (duckdb_pending_execution_is_finished(pending_state)) {
            snprintf(err_msg, err_cap, "rducks_query_stream reached unexpected finished pending state");
            return 0;
        }
    }
}

static int rducks_query_stream_copy_chunk(duckdb_data_chunk src, duckdb_data_chunk output,
                                          char *err_msg, size_t err_cap) {
    idx_t count;
    idx_t column_count;
    duckdb_selection_vector sel = NULL;
    sel_t *sel_data;

    if (!src || !output) {
        snprintf(err_msg, err_cap, "rducks_query_stream copy received an invalid chunk");
        return 0;
    }
    count = duckdb_data_chunk_get_size(src);
    column_count = duckdb_data_chunk_get_column_count(src);
    if (count == 0) {
        duckdb_data_chunk_set_size(output, 0);
        return 1;
    }

    sel = duckdb_create_selection_vector(count);
    if (!sel) {
        snprintf(err_msg, err_cap, "failed to allocate rducks_query_stream selection vector");
        return 0;
    }
    sel_data = duckdb_selection_vector_get_data_ptr(sel);
    for (idx_t row = 0; row < count; row++) sel_data[row] = (sel_t)row;

    for (idx_t col = 0; col < column_count; col++) {
        duckdb_vector src_vec = duckdb_data_chunk_get_vector(src, col);
        duckdb_vector dst_vec = duckdb_data_chunk_get_vector(output, col);
        duckdb_vector_copy_sel(src_vec, dst_vec, sel, count, 0, 0);
    }
    duckdb_destroy_selection_vector(sel);
    duckdb_data_chunk_set_size(output, count);
    return 1;
}

static void rducks_query_stream_function(duckdb_function_info info, duckdb_data_chunk output) {
    rducks_query_stream_state_t *state;
    duckdb_data_chunk chunk = NULL;
    char err_msg[512];
    err_msg[0] = '\0';

    if (!info || !output) return;
    state = (rducks_query_stream_state_t *)duckdb_function_get_init_data(info);
    if (!state) {
        duckdb_function_set_error(info, "rducks_query_stream state is missing");
        return;
    }
    if (!rducks_is_main_thread(state->runtime)) {
        duckdb_function_set_error(info, "rducks_query_stream must execute on the recorded main R lane");
        return;
    }
    if (state->exhausted) {
        duckdb_data_chunk_set_size(output, 0);
        return;
    }

    if (!rducks_query_stream_drive_to_result(state, err_msg, sizeof(err_msg))) {
        duckdb_function_set_error(info, err_msg[0] ? err_msg : "rducks_query_stream failed to drive pending query");
        return;
    }
    if (!state->has_result) {
        duckdb_data_chunk_set_size(output, 0);
        return;
    }

    (void)rducks_queue_drain_on_main(state->runtime, 1000000);
    chunk = duckdb_fetch_chunk(state->result);
    (void)rducks_queue_drain_on_main(state->runtime, 1000000);
    if (!chunk || duckdb_data_chunk_get_size(chunk) == 0) {
        if (chunk) duckdb_destroy_data_chunk(&chunk);
        state->exhausted = 1;
        duckdb_data_chunk_set_size(output, 0);
        return;
    }

    if (!rducks_query_stream_copy_chunk(chunk, output, err_msg, sizeof(err_msg))) {
        duckdb_destroy_data_chunk(&chunk);
        duckdb_function_set_error(info, err_msg[0] ? err_msg : "rducks_query_stream failed to copy result chunk");
        return;
    }
    duckdb_destroy_data_chunk(&chunk);
}

static bool rducks_register_query_stream(duckdb_connection con, rducks_runtime_entry_t *runtime) {
    duckdb_table_function fn = duckdb_create_table_function();
    duckdb_logical_type varchar_type = duckdb_create_logical_type(DUCKDB_TYPE_VARCHAR);
    duckdb_state rc;
    if (!fn || !varchar_type) {
        if (fn) duckdb_destroy_table_function(&fn);
        if (varchar_type) duckdb_destroy_logical_type(&varchar_type);
        return false;
    }
    duckdb_table_function_set_name(fn, "rducks_query_stream");
    duckdb_table_function_add_parameter(fn, varchar_type);
    duckdb_table_function_set_extra_info(fn, runtime, NULL);
    duckdb_table_function_set_bind(fn, rducks_query_stream_bind);
    duckdb_table_function_set_init(fn, rducks_query_stream_init);
    duckdb_table_function_set_function(fn, rducks_query_stream_function);
    rc = duckdb_register_table_function(con, fn);
    duckdb_destroy_table_function(&fn);
    duckdb_destroy_logical_type(&varchar_type);
    return rc == DuckDBSuccess;
}
