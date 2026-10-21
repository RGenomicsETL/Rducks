/* Included by ../rducks_extension.c. */

typedef enum rducks_query_stream_command {
    RDUCKS_STREAM_COMMAND_NONE = 0,
    RDUCKS_STREAM_COMMAND_EXECUTE,
    RDUCKS_STREAM_COMMAND_FETCH,
    RDUCKS_STREAM_COMMAND_CLOSE
} rducks_query_stream_command_t;

struct rducks_query_stream_entry {
    char *token;
    rducks_runtime_entry_t *runtime;
    duckdb_connection connection;
    duckdb_result result;
    int result_initialized;
    int done;
    int busy;
    int managed;
    rducks_query_owner_t *owner;
    char *sql;
    duckdb_prepared_statement statement;
    duckdb_pending_result pending;
    /* One fetched chunk is handed to the R thread at a time. It remains owned
     * by the entry across R allocations, including abnormal unwinds. */
    duckdb_data_chunk chunk;
    rducks_type_desc_t *materializing_type;
    rducks_query_stream_command_t command;
    atomic_int command_done;
    int command_ok;
    int driver_started;
    char driver_error[RDUCKS_ERROR_BUFFER_SIZE];
#ifdef _WIN32
    HANDLE driver;
#else
    pthread_t driver;
#endif
    idx_t column_count;
    duckdb_logical_type *types;
    char **names;
    SEXP schema_xptr;
    SEXP type_specs;
    SEXP column_names_sexp;
    struct rducks_query_stream_entry *next;
};

/* The helper is native-only. Prepare can execute constant scalar expressions;
 * pending creation, execution, fetching, and destruction can all execute or
 * wait for DuckDB tasks. Keep every such operation off the R service thread. */
static int rducks_query_stream_engine_execute(rducks_query_stream_entry_t *entry) {
    duckdb_state rc;
    const char *msg;
    if (entry->owner && rducks_query_owner_stopping(entry->owner)) return 0;
    rc = duckdb_prepare(entry->connection, entry->sql, &entry->statement);
    if (rc == DuckDBError) {
        msg = entry->statement ? duckdb_prepare_error(entry->statement) : NULL;
        rducks_copy_error_message(entry->driver_error, sizeof(entry->driver_error), msg,
                                  "DuckDB failed to prepare query stream");
        return 0;
    }
    if (entry->owner && rducks_query_owner_stopping(entry->owner)) return 0;
    rc = duckdb_pending_prepared_streaming(entry->statement, &entry->pending);
    if (rc == DuckDBError) {
        msg = entry->pending ? duckdb_pending_error(entry->pending) : NULL;
        rducks_copy_error_message(entry->driver_error, sizeof(entry->driver_error), msg,
                                  "DuckDB failed to create pending query stream");
        return 0;
    }
    if (entry->owner && rducks_query_owner_stopping(entry->owner)) return 0;
    entry->result_initialized = 1;
    rc = duckdb_execute_pending(entry->pending, &entry->result);
    duckdb_destroy_pending(&entry->pending);
    duckdb_destroy_prepare(&entry->statement);
    if (rc == DuckDBError) {
        rducks_copy_error_message(entry->driver_error, sizeof(entry->driver_error),
                                  duckdb_result_error(&entry->result), "DuckDB failed to open query stream");
        return 0;
    }
    if (!duckdb_result_is_streaming(entry->result)) {
        rducks_format_error_message(entry->driver_error, sizeof(entry->driver_error),
                                    "DuckDB did not create a streaming result for this query");
        return 0;
    }
    return 1;
}

static int rducks_query_stream_engine_fetch(rducks_query_stream_entry_t *entry) {
    const char *msg;
    if (entry->owner && rducks_query_owner_stopping(entry->owner)) return 0;
    entry->chunk = duckdb_stream_fetch_chunk(entry->result);
    if (entry->chunk && duckdb_data_chunk_get_size(entry->chunk) > 0) return 1;
    if (entry->chunk) duckdb_destroy_data_chunk(&entry->chunk);
    msg = duckdb_result_error(&entry->result);
    if (msg && msg[0]) {
        rducks_copy_error_message(entry->driver_error, sizeof(entry->driver_error), msg,
                                  "DuckDB query stream fetch failed");
        return 0;
    }
    entry->done = 1;
    return 1;
}

static void rducks_query_stream_engine_close(rducks_query_stream_entry_t *entry) {
    if (entry->chunk) duckdb_destroy_data_chunk(&entry->chunk);
    if (entry->pending) duckdb_destroy_pending(&entry->pending);
    if (entry->statement) duckdb_destroy_prepare(&entry->statement);
    if (entry->result_initialized) {
        duckdb_destroy_result(&entry->result);
        entry->result_initialized = 0;
    }
}

#ifdef _WIN32
static DWORD WINAPI rducks_query_stream_driver(LPVOID data) {
#else
static void *rducks_query_stream_driver(void *data) {
#endif
    rducks_query_stream_entry_t *entry = (rducks_query_stream_entry_t *)data;
    rducks_runtime_entry_t *runtime = entry->runtime;
    for (;;) {
        rducks_query_stream_command_t command;
        rducks_queue_lock(runtime);
        while (entry->command == RDUCKS_STREAM_COMMAND_NONE) {
#ifdef _WIN32
            SleepConditionVariableCS(&runtime->queue_cond, &runtime->queue_lock, INFINITE);
#else
            pthread_cond_wait(&runtime->queue_cond, &runtime->queue_lock);
#endif
        }
        command = entry->command;
        entry->command = RDUCKS_STREAM_COMMAND_NONE;
        rducks_queue_unlock(runtime);

        if (command == RDUCKS_STREAM_COMMAND_EXECUTE) {
            entry->command_ok = rducks_query_stream_engine_execute(entry);
        } else if (command == RDUCKS_STREAM_COMMAND_FETCH) {
            entry->command_ok = rducks_query_stream_engine_fetch(entry);
        } else {
            rducks_query_stream_engine_close(entry);
            entry->command_ok = 1;
        }
        atomic_store_explicit(&entry->command_done, 1, memory_order_release);
        rducks_queue_signal_all_locked(runtime);
        if (command == RDUCKS_STREAM_COMMAND_CLOSE) break;
    }
#ifdef _WIN32
    return 0;
#else
    return NULL;
#endif
}

static int rducks_query_stream_driver_start(rducks_query_stream_entry_t *entry,
                                            char *err_msg, size_t err_cap) {
#ifdef _WIN32
    entry->driver = CreateThread(NULL, 0, rducks_query_stream_driver, entry, 0, NULL);
    if (!entry->driver) {
#else
    if (pthread_create(&entry->driver, NULL, rducks_query_stream_driver, entry) != 0) {
#endif
        rducks_format_error_message(err_msg, err_cap, "failed to create Rducks query driver thread");
        return 0;
    }
    entry->driver_started = 1;
    return 1;
}

static void rducks_query_stream_driver_wait(rducks_query_stream_entry_t *entry, int check_interrupts) {
    rducks_runtime_entry_t *runtime = entry->runtime;
    uint64_t last_interrupt_check = 0U;
    while (!atomic_load_explicit(&entry->command_done, memory_order_acquire)) {
        uint64_t now = rducks_queue_now_us();
        if (check_interrupts && !rducks_query_owner_stopping(entry->owner) &&
            (now == 0U || last_interrupt_check == 0U || now < last_interrupt_check ||
             now - last_interrupt_check >= RDUCKS_QUEUE_INTERRUPT_CHECK_US)) {
            last_interrupt_check = now;
            atomic_fetch_add_explicit(&runtime->queue_interrupt_checks, 1U, memory_order_relaxed);
            if (!R_ToplevelExec(rducks_queue_check_user_interrupt_body, NULL)) {
                atomic_fetch_add_explicit(&runtime->queue_interrupts, 1U, memory_order_relaxed);
                rducks_queue_fail_owner(runtime, entry->owner, "Rducks managed query interrupted by user");
            }
        }
        /* Query setup may reset DuckDB's interrupt flag. Admission stays
         * closed in our owner, and repeating the native interrupt also stops
         * a query with no R callbacks when cancellation races setup. */
        if (rducks_query_owner_stopping(entry->owner)) duckdb_interrupt(entry->connection);
        (void)rducks_queue_drain_owner_on_main(runtime, entry->owner);
        rducks_queue_lock(runtime);
        if (!atomic_load_explicit(&entry->command_done, memory_order_acquire)) {
            (void)rducks_queue_wait_timed_us(runtime, 1000U);
        }
        rducks_queue_unlock(runtime);
    }
}

static int rducks_query_stream_driver_command(rducks_query_stream_entry_t *entry,
                                              rducks_query_stream_command_t command, int check_interrupts,
                                              char *err_msg, size_t err_cap) {
    rducks_queue_lock(entry->runtime);
    entry->command_ok = 0;
    entry->driver_error[0] = '\0';
    atomic_store_explicit(&entry->command_done, 0, memory_order_relaxed);
    entry->command = command;
    rducks_queue_signal_all(entry->runtime);
    rducks_queue_unlock(entry->runtime);
    rducks_query_stream_driver_wait(entry, check_interrupts);
    if (command == RDUCKS_STREAM_COMMAND_CLOSE) return 1;
    if (!entry->command_ok || rducks_query_owner_stopping(entry->owner)) {
        rducks_copy_error_message(err_msg, err_cap,
                                  entry->owner->error[0] ? entry->owner->error : entry->driver_error,
                                  "Rducks managed query was cancelled");
        return 0;
    }
    return 1;
}

static void rducks_query_stream_driver_stop(rducks_query_stream_entry_t *entry) {
    if (!entry->driver_started) return;
    /* Stop admission before waiting or destroying the result. PENDING
     * requests can leave; RUNNING requests retain their submitters until DONE.
     * After cancellation the pump rejects callbacks instead of evaluating R. */
    rducks_queue_stop_owner(entry->runtime, entry->owner);
    rducks_query_stream_driver_wait(entry, 0);
    (void)rducks_query_stream_driver_command(entry, RDUCKS_STREAM_COMMAND_CLOSE, 0, NULL, 0U);
#ifdef _WIN32
    WaitForSingleObject(entry->driver, INFINITE);
    CloseHandle(entry->driver);
    entry->driver = NULL;
#else
    pthread_join(entry->driver, NULL);
#endif
    entry->driver_started = 0;
}

static void rducks_query_stream_release_preserved(rducks_runtime_entry_t *runtime, SEXP object) {
    if (!object || object == R_NilValue) return;
    if (rducks_is_main_thread(runtime)) {
        rducks_preserved_release_now(object);
    } else {
        rducks_preserved_release_enqueue(object);
    }
}

static void rducks_query_stream_entry_destroy(rducks_query_stream_entry_t *entry) {
    if (!entry) return;
    if (entry->driver_started) rducks_query_stream_driver_stop(entry);
    else rducks_query_stream_engine_close(entry);
    rducks_runtime_lock();
    if (entry->runtime->query_stream_service_entry == entry) entry->runtime->query_stream_service_entry = NULL;
    if (entry->runtime->preparing_query_owner == entry->owner) entry->runtime->preparing_query_owner = NULL;
    rducks_runtime_unlock();
    if (entry->runtime && entry->connection && entry->runtime->query_stream_connection == entry->connection) {
        rducks_runtime_lock();
        entry->runtime->query_stream_connection_busy = 0;
        rducks_runtime_unlock();
    }
    if (entry->types) {
        for (idx_t i = 0; i < entry->column_count; i++) {
            if (entry->types[i]) duckdb_destroy_logical_type(&entry->types[i]);
        }
    }
    if (entry->names) {
        for (idx_t i = 0; i < entry->column_count; i++) free(entry->names[i]);
    }
    free(entry->types);
    free(entry->names);
    rducks_type_desc_destroy(entry->materializing_type);
    rducks_query_owner_release(entry->owner);
    free(entry->sql);
    rducks_query_stream_release_preserved(entry->runtime, entry->schema_xptr);
    rducks_query_stream_release_preserved(entry->runtime, entry->type_specs);
    rducks_query_stream_release_preserved(entry->runtime, entry->column_names_sexp);
    entry->schema_xptr = R_NilValue;
    entry->type_specs = R_NilValue;
    entry->column_names_sexp = R_NilValue;
    free(entry->token);
    memset(entry, 0, sizeof(*entry));
    free(entry);
}

static rducks_query_stream_entry_t *rducks_query_stream_find_locked(rducks_runtime_entry_t *runtime,
                                                                     const char *token,
                                                                     rducks_query_stream_entry_t ***prev_next) {
    rducks_query_stream_entry_t **link;
    if (prev_next) *prev_next = NULL;
    if (!runtime || !token || !token[0]) return NULL;
    link = &runtime->query_streams;
    while (*link) {
        if ((*link)->token && strcmp((*link)->token, token) == 0) {
            if (prev_next) *prev_next = link;
            return *link;
        }
        link = &(*link)->next;
    }
    return NULL;
}

static int rducks_query_stream_make_token(rducks_runtime_entry_t *runtime, char **token_out,
                                          char *err_msg, size_t err_cap) {
    uint64_t stream_id;
    uint64_t runtime_id;
    char buf[96];
    if (!runtime || !token_out) {
        rducks_format_error_message(err_msg, err_cap, "invalid Rducks query stream token request");
        return 0;
    }
    rducks_runtime_lock();
    stream_id = ++runtime->query_stream_next_id;
    runtime_id = runtime->runtime_id;
    rducks_runtime_unlock();
    snprintf(buf, sizeof(buf), "rducks-query-stream:%llu:%llu",
             (unsigned long long)runtime_id, (unsigned long long)stream_id);
    *token_out = rducks_strdup(buf);
    if (!*token_out) {
        rducks_format_error_message(err_msg, err_cap, "out of memory allocating Rducks query stream token");
        return 0;
    }
    return 1;
}

static int rducks_query_stream_capture_schema(rducks_query_stream_entry_t *entry,
                                              char *err_msg, size_t err_cap) {
    if (!entry) {
        rducks_format_error_message(err_msg, err_cap, "invalid Rducks query stream schema state");
        return 0;
    }
    entry->column_count = duckdb_column_count(&entry->result);
    if (entry->column_count == 0) return 1;

    entry->types = (duckdb_logical_type *)rducks_calloc_array((size_t)entry->column_count, sizeof(*entry->types));
    entry->names = (char **)rducks_calloc_array((size_t)entry->column_count, sizeof(*entry->names));
    if (!entry->types || !entry->names) {
        rducks_format_error_message(err_msg, err_cap, "out of memory allocating Rducks query stream schema");
        return 0;
    }

    for (idx_t i = 0; i < entry->column_count; i++) {
        const char *name = duckdb_column_name(&entry->result, i);
        entry->names[i] = rducks_strdup(name ? name : "");
        entry->types[i] = duckdb_column_logical_type(&entry->result, i);
        if (!entry->names[i] || !entry->types[i]) {
            rducks_format_error_message(err_msg, err_cap, "failed to copy Rducks query stream schema");
            return 0;
        }
    }
    return 1;
}

static int rducks_query_stream_metadata_native(rducks_runtime_entry_t *runtime, const char *token,
                                               char **metadata_out,
                                               char *err_msg, size_t err_cap) {
    rducks_query_stream_entry_t *entry;
    rducks_strbuf_t buf;
    int ok = 0;

    if (metadata_out) *metadata_out = NULL;
    memset(&buf, 0, sizeof(buf));
    if (!runtime || !token || !token[0] || !metadata_out) {
        rducks_format_error_message(err_msg, err_cap, "invalid Rducks query stream token");
        return 0;
    }

    rducks_runtime_lock();
    entry = rducks_query_stream_find_locked(runtime, token, NULL);
    rducks_runtime_unlock();
    if (!entry) {
        rducks_format_error_message(err_msg, err_cap, "Rducks query stream is closed");
        return 0;
    }

    for (idx_t i = 0; i < entry->column_count; i++) {
        duckdb_type type_id = duckdb_get_type_id(entry->types[i]);
        rducks_type_desc_t *desc = NULL;
        char *type_token = NULL;
        if (type_id == DUCKDB_TYPE_SQLNULL) {
            type_token = rducks_strdup("null");
            if (!type_token) {
                rducks_format_error_message(err_msg, err_cap, "out of memory formatting query stream metadata");
                goto cleanup;
            }
        } else {
            if (!rducks_type_desc_from_logical_type(entry->types[i], &desc, err_msg, err_cap)) goto cleanup;
            type_token = rducks_type_desc_token(desc);
            if (!type_token) {
                rducks_format_error_message(err_msg, err_cap, "out of memory formatting query stream type metadata");
                rducks_type_desc_destroy(desc);
                goto cleanup;
            }
        }
        if (!rducks_strbuf_append_token_name(&buf, entry->names[i] ? entry->names[i] : "") ||
            !rducks_strbuf_append_char(&buf, '\t') ||
            !rducks_strbuf_append(&buf, type_token) ||
            !rducks_strbuf_append_char(&buf, '\n')) {
            rducks_format_error_message(err_msg, err_cap, "out of memory formatting query stream metadata");
            free(type_token);
            rducks_type_desc_destroy(desc);
            goto cleanup;
        }
        free(type_token);
        rducks_type_desc_destroy(desc);
    }
    if (!buf.data && !rducks_strbuf_append(&buf, "")) {
        rducks_format_error_message(err_msg, err_cap, "out of memory formatting query stream metadata");
        goto cleanup;
    }
    *metadata_out = buf.data;
    buf.data = NULL;
    ok = 1;

cleanup:
    free(buf.data);
    return ok;
}

static int rducks_query_stream_open_native(rducks_runtime_entry_t *runtime, const char *sql,
                                           const char **token_out, char *err_msg, size_t err_cap) {
    rducks_query_stream_entry_t *entry = NULL;
    int linked = 0;
    if (token_out) *token_out = NULL;
    if (!runtime || !runtime->query_stream_connection) {
        rducks_format_error_message(err_msg, err_cap, "Rducks runtime has no DuckDB connection for query streaming");
        return 0;
    }
    if (!rducks_allow_calling_thread_r_execution(runtime, err_msg, err_cap)) return 0;
    if (!sql || !sql[0]) {
        rducks_format_error_message(err_msg, err_cap, "sql must be a non-empty character scalar");
        return 0;
    }
    entry = (rducks_query_stream_entry_t *)calloc(1, sizeof(*entry));
    if (!entry) {
        rducks_format_error_message(err_msg, err_cap, "out of memory allocating Rducks query stream");
        return 0;
    }
    entry->runtime = runtime;
    entry->managed = rducks_concurrent_inproc_enabled(runtime);
    entry->schema_xptr = R_NilValue;
    entry->type_specs = R_NilValue;
    entry->column_names_sexp = R_NilValue;
    atomic_init(&entry->command_done, 1);

    rducks_runtime_lock();
    if (runtime->query_stream_connection_busy) {
        rducks_runtime_unlock();
        rducks_format_error_message(err_msg, err_cap, "Rducks supports one active native query stream per runtime");
        goto error;
    }
    runtime->query_stream_connection_busy = 1;
    entry->connection = runtime->query_stream_connection;
    entry->busy = 1;
    if (runtime->query_stream_service_active) runtime->query_stream_service_entry = entry;
    rducks_runtime_unlock();

    if (!rducks_query_stream_make_token(runtime, &entry->token, err_msg, err_cap)) goto error;
    entry->sql = rducks_strdup(sql);
    if (!entry->sql) {
        rducks_format_error_message(err_msg, err_cap, "out of memory copying Rducks query stream SQL");
        goto error;
    }
    if (entry->managed) {
        entry->owner = rducks_query_owner_create(entry->connection);
        if (!entry->owner) {
            rducks_format_error_message(err_msg, err_cap, "failed to allocate Rducks query cancellation owner");
            goto error;
        }
    }
    /* Register before execution: the bridge's unwind cleanup can now locate
     * and close a partially constructed stream, including its helper. */
    rducks_runtime_lock();
    entry->next = runtime->query_streams;
    runtime->query_streams = entry;
    runtime->preparing_query_owner = entry->owner;
    linked = 1;
    rducks_runtime_unlock();
    if (entry->managed) {
        if (!rducks_query_stream_driver_start(entry, err_msg, err_cap) ||
            !rducks_query_stream_driver_command(entry, RDUCKS_STREAM_COMMAND_EXECUTE, 1, err_msg, err_cap)) goto error;
    } else if (!rducks_query_stream_engine_execute(entry)) {
        rducks_copy_error_message(err_msg, err_cap, entry->driver_error, "DuckDB failed to open query stream");
        goto error;
    }
    rducks_runtime_lock();
    runtime->preparing_query_owner = NULL;
    rducks_runtime_unlock();
    free(entry->sql);
    entry->sql = NULL;
    if (!rducks_query_stream_capture_schema(entry, err_msg, err_cap)) goto error;
    entry->busy = 0;
    if (token_out) *token_out = entry->token;
    return 1;

error:
    if (linked) {
        rducks_query_stream_entry_t **link = NULL;
        rducks_runtime_lock();
        (void)rducks_query_stream_find_locked(runtime, entry->token, &link);
        if (link) *link = entry->next;
        entry->next = NULL;
        rducks_runtime_unlock();
    }
    rducks_query_stream_entry_destroy(entry);
    return 0;
}

static int rducks_query_stream_close_native(rducks_runtime_entry_t *runtime, const char *token,
                                            int *closed_out, char *err_msg, size_t err_cap) {
    rducks_query_stream_entry_t **prev_next = NULL;
    rducks_query_stream_entry_t *entry;
    if (closed_out) *closed_out = 0;
    if (!runtime || !token || !token[0]) return 1;
    if (!rducks_allow_calling_thread_r_execution(runtime, err_msg, err_cap)) return 0;
    rducks_runtime_lock();
    entry = rducks_query_stream_find_locked(runtime, token, &prev_next);
    if (entry && entry->busy) {
        rducks_runtime_unlock();
        rducks_format_error_message(err_msg, err_cap, "Rducks query stream is already active");
        return 0;
    }
    if (entry && prev_next) {
        *prev_next = entry->next;
        entry->next = NULL;
    }
    rducks_runtime_unlock();
    if (!entry) return 1;
    rducks_query_stream_entry_destroy(entry);
    if (closed_out) *closed_out = 1;
    return 1;
}

static void rducks_query_stream_destroy_detached_list(rducks_query_stream_entry_t *entry) {
    while (entry) {
        rducks_query_stream_entry_t *next = entry->next;
        entry->next = NULL;
        rducks_query_stream_entry_destroy(entry);
        entry = next;
    }
}

static int rducks_query_stream_schema_native(rducks_runtime_entry_t *runtime, const char *token,
                                             char *err_msg, size_t err_cap) {
    rducks_query_stream_entry_t *entry;
    if (!runtime || !token || !token[0]) {
        rducks_format_error_message(err_msg, err_cap, "invalid Rducks query stream token");
        return 0;
    }
    rducks_runtime_lock();
    entry = rducks_query_stream_find_locked(runtime, token, NULL);
    rducks_runtime_unlock();
    if (!entry) {
        rducks_format_error_message(err_msg, err_cap, "Rducks query stream is closed");
        return 0;
    }
    return 1;
}

/* Materialize a fetched DuckDB chunk directly into an R data frame (one column
 * per result column via the same DuckDB-vector -> SEXP readers used for scalar
 * UDF inputs) and hand it to the R side. In-process streaming shares the address
 * space with DuckDB, so there is no wire codec. */
static int rducks_query_stream_store_chunk(rducks_query_stream_entry_t *entry,
                                            duckdb_data_chunk chunk, char *err_msg, size_t err_cap) {
    idx_t n = duckdb_data_chunk_get_size(chunk);
    idx_t ncol = entry->column_count;
    SEXP df, names, pkg, ns, fun, tok, call;
    int r_err = 0;
    int nprot = 0;
    df = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)ncol)); nprot++;
    names = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)ncol)); nprot++;
    for (idx_t c = 0; c < ncol; c++) {
        duckdb_vector vec = duckdb_data_chunk_get_vector(chunk, c);
        SEXP col;
        if (!vec) {
            rducks_format_error_message(err_msg, err_cap, "Rducks query stream chunk vector is missing");
            UNPROTECT(nprot);
            return 0;
        }
        if (!rducks_type_desc_from_logical_type(entry->types[c], &entry->materializing_type, err_msg, err_cap)) {
            UNPROTECT(nprot);
            return 0;
        }
        col = rducks_rc_direct_column_values(entry->materializing_type, vec, n, err_msg, err_cap);
        rducks_type_desc_destroy(entry->materializing_type);
        entry->materializing_type = NULL;
        if (!col) {
            UNPROTECT(nprot);
            return 0;
        }
        SET_VECTOR_ELT(df, (R_xlen_t)c, col);
        SET_STRING_ELT(names, (R_xlen_t)c, Rf_mkChar(entry->names[c] ? entry->names[c] : ""));
    }
    Rf_setAttrib(df, R_NamesSymbol, names);
    pkg = PROTECT(Rf_mkString("Rducks")); nprot++;
    ns = PROTECT(R_FindNamespace(pkg)); nprot++;
    fun = PROTECT(Rf_findFun(Rf_install("rducks_query_stream_store_native_batch"), ns)); nprot++;
    tok = PROTECT(Rf_mkString(entry->token)); nprot++;
    {
        SEXP nrows = PROTECT(Rf_ScalarReal((double)n)); nprot++;
        call = PROTECT(Rf_lang4(fun, tok, df, nrows)); nprot++;
    }
    R_tryEvalSilent(call, R_GlobalEnv, &r_err);
    UNPROTECT(nprot);
    if (r_err) {
        rducks_format_error_message(err_msg, err_cap, "failed to store Rducks query stream batch");
        return 0;
    }
    return 1;
}

static int rducks_query_stream_next_native(rducks_runtime_entry_t *runtime, const char *token,
                                           int *has_batch_out, char *err_msg, size_t err_cap) {
    rducks_query_stream_entry_t *entry;
    int ok = 0;
    if (has_batch_out) *has_batch_out = 0;
    if (!runtime || !token || !token[0]) {
        rducks_format_error_message(err_msg, err_cap, "invalid Rducks query stream token");
        return 0;
    }
    if (!rducks_allow_calling_thread_r_execution(runtime, err_msg, err_cap)) return 0;
    rducks_runtime_lock();
    entry = rducks_query_stream_find_locked(runtime, token, NULL);
    if (entry && entry->busy) {
        rducks_runtime_unlock();
        rducks_format_error_message(err_msg, err_cap, "Rducks query stream is already active");
        return 0;
    }
    if (entry) {
        entry->busy = 1;
        if (runtime->query_stream_service_active) runtime->query_stream_service_entry = entry;
    }
    rducks_runtime_unlock();
    if (!entry) {
        rducks_format_error_message(err_msg, err_cap, "Rducks query stream is closed");
        return 0;
    }
    if (entry->done) {
        ok = 1;
        goto cleanup;
    }
    if (entry->managed) {
        if (!rducks_query_stream_driver_command(entry, RDUCKS_STREAM_COMMAND_FETCH, 1, err_msg, err_cap)) goto cleanup;
    } else if (!rducks_query_stream_engine_fetch(entry)) {
        rducks_copy_error_message(err_msg, err_cap, entry->driver_error, "DuckDB query stream fetch failed");
        goto cleanup;
    }
    if (entry->done) {
        /* EOF has no outstanding consumer buffer. Join now; the small schema
         * handle remains valid until the R wrapper's idempotent close. */
        if (entry->managed) rducks_query_stream_driver_stop(entry);
        ok = 1;
        goto cleanup;
    }
    if (!rducks_query_stream_store_chunk(entry, entry->chunk, err_msg, err_cap)) goto cleanup;
    if (has_batch_out) *has_batch_out = 1;
    ok = 1;

cleanup:
    if (entry->chunk) duckdb_destroy_data_chunk(&entry->chunk);
    rducks_runtime_lock();
    entry->busy = 0;
    rducks_runtime_unlock();
    if (!ok) {
        /* Errors terminate the stream before control returns to R. Reuse of
         * the internal connection never races a surviving driver or callback. */
        (void)rducks_query_stream_close_native(runtime, token, NULL, NULL, 0U);
    }
    return ok;
}

static int rducks_query_stream_service_is_active(rducks_runtime_entry_t *runtime) {
    rducks_query_stream_entry_t *entry;
    int active;
    rducks_runtime_lock();
    active = runtime->query_stream_service_active;
    for (entry = runtime->query_streams; !active && entry; entry = entry->next) active = entry->busy;
    rducks_runtime_unlock();
    return active;
}

typedef struct rducks_query_stream_bridge_call {
    rducks_runtime_entry_t *runtime;
    const char *operation;
    const char *argument;
    char *metadata;
    int activated;
} rducks_query_stream_bridge_call_t;

static SEXP rducks_query_stream_guard_version_body(void *data) {
    typedef uint32_t (*rducks_off_main_guard_version_fn)(void);
    uint32_t *version = (uint32_t *)data;
    rducks_off_main_guard_version_fn read_version = (rducks_off_main_guard_version_fn)
        R_GetCCallable("duckdb", "duckdb_r_off_main_guard_version");
    *version = read_version();
    return R_NilValue;
}

static SEXP rducks_query_stream_guard_version_missing(SEXP condition, void *data) {
    (void)condition;
    (void)data;
    return R_NilValue;
}

static int rducks_query_stream_driver_supported(void) {
    uint32_t version = 0U;
    (void)R_tryCatchError(rducks_query_stream_guard_version_body, &version,
                          rducks_query_stream_guard_version_missing, &version);
    return version >= 1U;
}

static SEXP rducks_query_stream_bridge_body(void *data) {
    rducks_query_stream_bridge_call_t *call = (rducks_query_stream_bridge_call_t *)data;
    rducks_runtime_entry_t *runtime = call->runtime;
    char error[RDUCKS_ERROR_BUFFER_SIZE] = {0};
    const char *token = NULL;
    int value = 0;
    rducks_runtime_lock();
    if (runtime->query_stream_service_active) {
        rducks_runtime_unlock();
        Rf_error("Rducks query stream service is already active; recursive operations are unsupported");
    }
    runtime->query_stream_service_active = 1;
    runtime->query_stream_service_entry = NULL;
    call->activated = 1;
    rducks_runtime_unlock();
    if (strcmp(call->operation, "close_all") == 0) {
        rducks_query_stream_entry_t *entries;
        rducks_runtime_lock();
        entries = runtime->query_streams;
        runtime->query_streams = NULL;
        rducks_runtime_unlock();
        rducks_query_stream_destroy_detached_list(entries);
        return Rf_ScalarLogical(1);
    }
    if ((strcmp(call->operation, "open") == 0 || strcmp(call->operation, "next") == 0) &&
        !rducks_concurrent_inproc_enabled(runtime)) {
        Rf_error("the native managed query entry requires the inproc execution plan");
    }
    if (strcmp(call->operation, "open") == 0) {
        /* duckdb-r installs database-wide R replacement scans. An internal
         * connection inherits them too. Require its native off-main guards
         * before preparing arbitrary SQL on the helper; source promises or
         * SQL-text screening cannot establish this thread-safety boundary. */
        if (!rducks_query_stream_driver_supported()) {
            Rf_error("managed inproc query streams require duckdb-r off-main R-source guards (capability version 1)");
        }
        if (!rducks_query_stream_open_native(runtime, call->argument, &token, error, sizeof(error))) {
            Rf_error("%s", error);
        }
        return Rf_mkString(token);
    }
    if (strcmp(call->operation, "next") == 0) {
        if (!rducks_query_stream_next_native(runtime, call->argument, &value, error, sizeof(error))) {
            Rf_error("%s", error);
        }
        return Rf_ScalarLogical(value);
    }
    if (strcmp(call->operation, "close") == 0) {
        if (!rducks_query_stream_close_native(runtime, call->argument, &value, error, sizeof(error))) {
            Rf_error("%s", error);
        }
        return Rf_ScalarLogical(value);
    }
    if (!rducks_query_stream_metadata_native(runtime, call->argument, &call->metadata, error, sizeof(error))) {
        Rf_error("%s", error);
    }
    return Rf_mkString(call->metadata);
}

static void rducks_query_stream_bridge_cleanup(void *data, Rboolean jump) {
    rducks_query_stream_bridge_call_t *call = (rducks_query_stream_bridge_call_t *)data;
    rducks_runtime_entry_t *runtime = call->runtime;
    rducks_query_stream_entry_t *entry = NULL;
    if (call->activated) {
        if (jump) {
            rducks_query_stream_entry_t **link = NULL;
            rducks_runtime_lock();
            entry = runtime->query_stream_service_entry;
            if (entry && entry->token) {
                (void)rducks_query_stream_find_locked(runtime, entry->token, &link);
                if (link) *link = entry->next;
                entry->next = NULL;
            }
            rducks_runtime_unlock();
            /* No R callback may run after an unwind starts. Stop admission,
             * settle every borrowed request, then join and free native state. */
            if (entry) rducks_query_stream_entry_destroy(entry);
        }
        rducks_runtime_lock();
        runtime->query_stream_service_entry = NULL;
        runtime->query_stream_service_active = 0;
        rducks_runtime_unlock();
    }
    free(call->metadata);
    call->metadata = NULL;
}

/* A versioned runtime token identifies extension-owned state. No duckdb-r
 * external pointer layout is inspected, and no caller connection is borrowed. */
static SEXP rducks_query_stream_bridge(SEXP runtime_token, SEXP operation, SEXP argument) {
    rducks_query_stream_bridge_call_t call = {0};
    const char *token;
    char candidate[96];
    if (TYPEOF(runtime_token) != STRSXP || XLENGTH(runtime_token) != 1 || STRING_ELT(runtime_token, 0) == NA_STRING ||
        TYPEOF(operation) != STRSXP || XLENGTH(operation) != 1 || STRING_ELT(operation, 0) == NA_STRING ||
        TYPEOF(argument) != STRSXP || XLENGTH(argument) != 1 || STRING_ELT(argument, 0) == NA_STRING) {
        Rf_error("invalid Rducks query stream bridge arguments");
    }
    token = CHAR(STRING_ELT(runtime_token, 0));
    call.operation = CHAR(STRING_ELT(operation, 0));
    call.argument = CHAR(STRING_ELT(argument, 0));
    rducks_runtime_lock();
    for (idx_t i = 0; i < g_runtime_count; i++) {
        rducks_runtime_entry_t *runtime = g_runtime_entries[i];
        snprintf(candidate, sizeof(candidate), "rducks-runtime-%llu-%llu",
                 (unsigned long long)runtime->runtime_id, (unsigned long long)runtime->generation);
        if (strcmp(token, candidate) == 0 && runtime->query_stream_connection) {
            call.runtime = runtime;
            break;
        }
    }
    rducks_runtime_unlock();
    if (!call.runtime && strcmp(call.operation, "close") == 0) return Rf_ScalarLogical(0);
    if (!call.runtime) Rf_error("Rducks query stream runtime has been released");
    if (!rducks_is_main_thread(call.runtime)) Rf_error("Rducks query stream bridge must run on the recorded R thread");
    if (rducks_query_stream_service_is_active(call.runtime)) {
        Rf_error("Rducks query stream service is already active; recursive operations are unsupported");
    }
    if (strcmp(call.operation, "assert_idle") == 0) return Rf_ScalarLogical(1);
    if (strcmp(call.operation, "driver_supported") == 0) {
        return Rf_ScalarLogical(rducks_query_stream_driver_supported());
    }
    if (strcmp(call.operation, "assert_configurable") == 0) {
        int busy;
        rducks_runtime_lock();
        busy = call.runtime->query_stream_connection_busy;
        rducks_runtime_unlock();
        if (busy) Rf_error("close the active Rducks query stream before changing execution plans");
        return Rf_ScalarLogical(1);
    }
    if (strcmp(call.operation, "open") && strcmp(call.operation, "next") &&
        strcmp(call.operation, "close") && strcmp(call.operation, "metadata") && strcmp(call.operation, "close_all")) {
        Rf_error("unsupported Rducks query stream operation");
    }
    return R_UnwindProtect(rducks_query_stream_bridge_body, &call,
                           rducks_query_stream_bridge_cleanup, &call, NULL);
}

static void rducks_query_stream_register_bridge(rducks_runtime_entry_t *runtime) {
    char token[96];
    if (!runtime || !rducks_is_main_thread(runtime)) return;
    rducks_runtime_lock();
    snprintf(token, sizeof(token), "rducks-runtime-%llu-%llu",
             (unsigned long long)runtime->runtime_id, (unsigned long long)runtime->generation);
    rducks_runtime_unlock();
    R_RegisterCCallable("Rducks", token, (DL_FUNC)rducks_query_stream_bridge);
}
