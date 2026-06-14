/* Included by ../rducks_extension.c. */

struct rducks_query_stream_entry {
    char *token;
    rducks_runtime_entry_t *runtime;
    duckdb_connection connection;
    duckdb_result result;
    int result_initialized;
    int done;
    int busy;
    idx_t column_count;
    duckdb_logical_type *types;
    char **names;
    SEXP schema_xptr;
    SEXP type_specs;
    SEXP column_names_sexp;
    struct rducks_query_stream_entry *next;
};

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
    if (entry->result_initialized) {
        duckdb_destroy_result(&entry->result);
        entry->result_initialized = 0;
    }
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
    duckdb_prepared_statement stmt = NULL;
    duckdb_pending_result pending = NULL;
    rducks_query_stream_entry_t *entry = NULL;
    duckdb_state rc;

    if (token_out) *token_out = NULL;
    if (!runtime || !runtime->query_stream_connection) {
        rducks_format_error_message(err_msg, err_cap, "Rducks runtime has no DuckDB connection for query streaming");
        return 0;
    }
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
    entry->schema_xptr = R_NilValue;
    entry->type_specs = R_NilValue;
    entry->column_names_sexp = R_NilValue;
    memset(&entry->result, 0, sizeof(entry->result));

    rducks_runtime_lock();
    if (runtime->query_stream_connection_busy) {
        rducks_runtime_unlock();
        rducks_format_error_message(err_msg, err_cap, "Rducks supports one active native query stream per connection");
        goto error;
    }
    runtime->query_stream_connection_busy = 1;
    entry->connection = runtime->query_stream_connection;
    rducks_runtime_unlock();

    if (!rducks_query_stream_make_token(runtime, &entry->token, err_msg, err_cap)) goto error;
    rc = duckdb_prepare(entry->connection, sql, &stmt);
    if (rc == DuckDBError) {
        const char *msg = stmt ? duckdb_prepare_error(stmt) : NULL;
        rducks_copy_error_message(err_msg, err_cap, msg, "DuckDB failed to prepare query stream");
        goto error;
    }

    rc = duckdb_pending_prepared_streaming(stmt, &pending);
    duckdb_destroy_prepare(&stmt);
    stmt = NULL;
    if (rc == DuckDBError) {
        const char *msg = pending ? duckdb_pending_error(pending) : NULL;
        rducks_copy_error_message(err_msg, err_cap, msg, "DuckDB failed to create pending query stream");
        goto error;
    }

    rc = duckdb_execute_pending(pending, &entry->result);
    entry->result_initialized = 1;
    duckdb_destroy_pending(&pending);
    pending = NULL;
    if (rc == DuckDBError) {
        const char *msg = duckdb_result_error(&entry->result);
        rducks_copy_error_message(err_msg, err_cap, msg, "DuckDB failed to open query stream");
        goto error;
    }
    if (!duckdb_result_is_streaming(entry->result)) {
        rducks_format_error_message(err_msg, err_cap, "DuckDB did not create a streaming result for this query");
        goto error;
    }
    if (!rducks_query_stream_capture_schema(entry, err_msg, err_cap)) goto error;

    rducks_runtime_lock();
    entry->next = runtime->query_streams;
    runtime->query_streams = entry;
    rducks_runtime_unlock();
    if (token_out) *token_out = entry->token;
    return 1;

error:
    if (pending) duckdb_destroy_pending(&pending);
    if (stmt) duckdb_destroy_prepare(&stmt);
    rducks_query_stream_entry_destroy(entry);
    return 0;
}

static int rducks_query_stream_close_native(rducks_runtime_entry_t *runtime, const char *token,
                                            int *closed_out) {
    rducks_query_stream_entry_t **prev_next = NULL;
    rducks_query_stream_entry_t *entry;
    if (closed_out) *closed_out = 0;
    if (!runtime || !token || !token[0]) return 1;

    rducks_runtime_lock();
    entry = rducks_query_stream_find_locked(runtime, token, &prev_next);
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
        rducks_type_desc_t *desc = NULL;
        duckdb_vector vec = duckdb_data_chunk_get_vector(chunk, c);
        SEXP col;
        if (!vec) {
            rducks_format_error_message(err_msg, err_cap, "Rducks query stream chunk vector is missing");
            UNPROTECT(nprot);
            return 0;
        }
        if (!rducks_type_desc_from_logical_type(entry->types[c], &desc, err_msg, err_cap)) {
            UNPROTECT(nprot);
            return 0;
        }
        col = rducks_rc_direct_column_values(desc, vec, n, err_msg, err_cap);
        rducks_type_desc_destroy(desc);
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
    duckdb_data_chunk chunk = NULL;
    int ok = 0;
    if (has_batch_out) *has_batch_out = 0;
    if (!runtime || !token || !token[0]) {
        rducks_format_error_message(err_msg, err_cap, "invalid Rducks query stream token");
        return 0;
    }
    /* Materializing a batch allocates SEXPs and calls back into R, so it must run
     * on the recorded R thread. Reject off-main DuckDB worker threads. */
    if (!rducks_allow_calling_thread_r_execution(runtime, err_msg, err_cap)) {
        return 0;
    }

    rducks_runtime_lock();
    entry = rducks_query_stream_find_locked(runtime, token, NULL);
    if (entry && entry->busy) {
        rducks_runtime_unlock();
        rducks_format_error_message(err_msg, err_cap, "Rducks query stream is already active");
        return 0;
    }
    if (entry) entry->busy = 1;
    rducks_runtime_unlock();

    if (!entry) {
        rducks_format_error_message(err_msg, err_cap, "Rducks query stream is closed");
        return 0;
    }
    if (entry->done) {
        ok = 1;
        goto cleanup;
    }

    chunk = duckdb_stream_fetch_chunk(entry->result);
    if (!chunk || duckdb_data_chunk_get_size(chunk) == 0) {
        const char *msg = duckdb_result_error(&entry->result);
        if (msg && msg[0]) {
            rducks_copy_error_message(err_msg, err_cap, msg, "DuckDB query stream fetch failed");
            goto cleanup;
        }
        entry->done = 1;
        ok = 1;
        goto cleanup;
    }
    if (!rducks_query_stream_store_chunk(entry, chunk, err_msg, err_cap)) goto cleanup;
    if (has_batch_out) *has_batch_out = 1;
    ok = 1;

cleanup:
    if (chunk) duckdb_destroy_data_chunk(&chunk);
    rducks_runtime_lock();
    if (entry) entry->busy = 0;
    rducks_runtime_unlock();
    return ok;
}
