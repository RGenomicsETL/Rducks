/* Included by ../rducks_extension.c. */

#define RDUCKS_TABLE_DEFAULT_CHUNK_SIZE 1024ULL

typedef struct rducks_r_table_meta {
    SEXP fun;
    char *name;
    rducks_runtime_entry_t *runtime;
    size_t column_count;
    char **column_names;
    rducks_type_desc_t **column_descs;
    idx_t chunk_size;
} rducks_r_table_meta_t;

typedef struct rducks_r_table_state {
    rducks_r_table_meta_t *meta;
    SEXP result;
    SEXP *columns;
    idx_t rows;
    idx_t pos;
    int evaluated;
} rducks_r_table_state_t;

static void rducks_r_table_release_preserved(rducks_runtime_entry_t *runtime, SEXP object) {
    if (!object || object == R_NilValue) return;
    if (rducks_is_main_thread(runtime)) {
        rducks_preserved_release_now(object);
    } else {
        rducks_preserved_release_enqueue(object);
    }
}

static void rducks_r_table_meta_destroy(void *ptr) {
    rducks_r_table_meta_t *meta = (rducks_r_table_meta_t *)ptr;
    if (!meta) return;
    rducks_r_table_release_preserved(meta->runtime, meta->fun);
    meta->fun = R_NilValue;
    free(meta->name);
    if (meta->column_names) {
        for (size_t i = 0; i < meta->column_count; i++) free(meta->column_names[i]);
    }
    free(meta->column_names);
    if (meta->column_descs) {
        for (size_t i = 0; i < meta->column_count; i++) rducks_type_desc_destroy(meta->column_descs[i]);
    }
    free(meta->column_descs);
    free(meta);
}

static void rducks_r_table_state_destroy(void *ptr) {
    rducks_r_table_state_t *state = (rducks_r_table_state_t *)ptr;
    if (!state) return;
    rducks_r_table_release_preserved(state->meta ? state->meta->runtime : NULL, state->result);
    state->result = R_NilValue;
    free(state->columns);
    free(state);
}

static void rducks_r_table_set_r_error(SEXP err_obj, const char *fallback, char *err, size_t err_cap) {
    int r_err = 0;
    if (!err || err_cap == 0) return;
    snprintf(err, err_cap, "%s", fallback ? fallback : "Rducks table R function or marshal error");
    const char *cur_error = R_curErrorBuf();
    if (cur_error && cur_error[0]) {
        snprintf(err, err_cap, "%s: %s", fallback ? fallback : "Rducks table R function or marshal error", cur_error);
        return;
    }
    if (!err_obj || err_obj == R_NilValue) return;
    if (TYPEOF(err_obj) == STRSXP && XLENGTH(err_obj) > 0 && STRING_ELT(err_obj, 0) != NA_STRING) {
        snprintf(err, err_cap, "%s: %s", fallback ? fallback : "Rducks table R function or marshal error",
                 CHAR(STRING_ELT(err_obj, 0)));
        return;
    }
    SEXP call = PROTECT(Rf_lang2(Rf_install("conditionMessage"), err_obj));
    SEXP msg = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, &r_err));
    if (!r_err && TYPEOF(msg) == STRSXP && XLENGTH(msg) > 0 && STRING_ELT(msg, 0) != NA_STRING) {
        snprintf(err, err_cap, "%s: %s", fallback ? fallback : "Rducks table R function or marshal error",
                 CHAR(STRING_ELT(msg, 0)));
    }
    UNPROTECT(2);
}

static int rducks_parse_table_column_names(const char *text, char ***out, size_t *out_count,
                                           char *err, size_t err_cap) {
    char **items = NULL;
    size_t count = 0;
    size_t capacity = 0;
    const char *cursor;
    if (!out || !out_count) return 0;
    *out = NULL;
    *out_count = 0;
    if (!text || !text[0]) {
        snprintf(err, err_cap, "Rducks table returns must have at least one named column");
        return 0;
    }
    cursor = text;
    while (1) {
        const char *sep = strchr(cursor, ',');
        size_t len = sep ? (size_t)(sep - cursor) : strlen(cursor);
        char *name;
        if (len == 0) {
            snprintf(err, err_cap, "Rducks table column names must be non-empty");
            goto fail;
        }
        if (count == capacity) {
            size_t new_capacity = capacity ? capacity * 2U : 4U;
            char **new_items = (char **)rducks_realloc_array(items, new_capacity, sizeof(*new_items));
            if (!new_items) {
                snprintf(err, err_cap, "out of memory parsing Rducks table column names");
                goto fail;
            }
            items = new_items;
            capacity = new_capacity;
        }
        name = rducks_strdup_len(cursor, len);
        if (!name) {
            snprintf(err, err_cap, "out of memory copying Rducks table column name");
            goto fail;
        }
        items[count++] = name;
        if (!sep) break;
        cursor = sep + 1;
    }
    *out = items;
    *out_count = count;
    return 1;

fail:
    if (items) {
        for (size_t i = 0; i < count; i++) free(items[i]);
    }
    free(items);
    return 0;
}

static void rducks_r_table_bind(duckdb_bind_info info) {
    rducks_r_table_meta_t *meta;
    if (!info) return;
    meta = (rducks_r_table_meta_t *)duckdb_bind_get_extra_info(info);
    if (!meta) {
        duckdb_bind_set_error(info, "Rducks table metadata is missing");
        return;
    }
    if (duckdb_bind_get_parameter_count(info) != 0) {
        duckdb_bind_set_error(info, "Rducks R table functions registered by rducks_register_table() do not accept SQL arguments yet");
        return;
    }
    for (size_t i = 0; i < meta->column_count; i++) {
        duckdb_logical_type type = rducks_create_logical_type_for_desc(meta->column_descs[i]);
        if (!type) {
            duckdb_bind_set_error(info, "failed to allocate DuckDB logical type for Rducks table column");
            return;
        }
        duckdb_bind_add_result_column(info, meta->column_names[i], type);
        duckdb_destroy_logical_type(&type);
    }
}

static void rducks_r_table_init(duckdb_init_info info) {
    rducks_r_table_state_t *state;
    if (!info) return;
    state = (rducks_r_table_state_t *)rducks_calloc_array(1, sizeof(*state));
    if (!state) {
        duckdb_init_set_error(info, "out of memory allocating Rducks table state");
        return;
    }
    state->meta = (rducks_r_table_meta_t *)duckdb_init_get_extra_info(info);
    state->result = R_NilValue;
    if (!state->meta) {
        free(state);
        duckdb_init_set_error(info, "Rducks table metadata is missing");
        return;
    }
    duckdb_init_set_max_threads(info, 1);
    duckdb_init_set_init_data(info, state, rducks_r_table_state_destroy);
}

static int rducks_r_table_evaluate_once(rducks_r_table_state_t *state, char *err, size_t err_cap) {
    rducks_r_table_meta_t *meta = state ? state->meta : NULL;
    int r_err = 0;
    idx_t rows = 0;
    int have_rows = 0;
    if (!state || !meta || !meta->runtime || !Rf_isFunction(meta->fun)) {
        snprintf(err, err_cap, "Rducks table state is invalid");
        return 0;
    }
    if (!rducks_allow_calling_thread_r_execution(meta->runtime, err, err_cap)) {
        return 0;
    }
    rducks_preserved_release_drain_on_main(meta->runtime);

    SEXP call = PROTECT(Rf_lang1(meta->fun));
    SEXP result = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, &r_err));
    if (r_err) {
        rducks_r_table_set_r_error(result, "Rducks table R function or marshal error", err, err_cap);
        UNPROTECT(2);
        return 0;
    }
    if (TYPEOF(result) != VECSXP) {
        snprintf(err, err_cap, "Rducks table function must return a data frame or named list of columns");
        UNPROTECT(2);
        return 0;
    }

    state->columns = (SEXP *)rducks_calloc_array(meta->column_count, sizeof(*state->columns));
    if (!state->columns) {
        snprintf(err, err_cap, "out of memory recording Rducks table columns");
        UNPROTECT(2);
        return 0;
    }

    for (size_t col = 0; col < meta->column_count; col++) {
        int ok = 1;
        SEXP column = PROTECT(rducks_rc_named_field(result, meta->column_names[col], &ok));
        if (!ok) {
            snprintf(err, err_cap, "Rducks table result is missing output column %s", meta->column_names[col]);
            UNPROTECT(3);
            return 0;
        }
        R_xlen_t len = XLENGTH(column);
        if (len < 0 || (uint64_t)len > (uint64_t)((idx_t)-1)) {
            snprintf(err, err_cap, "Rducks table column %s has invalid length", meta->column_names[col]);
            UNPROTECT(3);
            return 0;
        }
        if (!have_rows) {
            rows = (idx_t)len;
            have_rows = 1;
        } else if (rows != (idx_t)len) {
            snprintf(err, err_cap, "Rducks table result columns must have equal lengths");
            UNPROTECT(3);
            return 0;
        }
        state->columns[col] = column;
        UNPROTECT(1);
    }

    R_PreserveObject(result);
    state->result = result;
    state->rows = rows;
    state->pos = 0;
    state->evaluated = 1;
    UNPROTECT(2);
    return 1;
}

static void rducks_r_table_function(duckdb_function_info info, duckdb_data_chunk output) {
    rducks_r_table_state_t *state;
    rducks_r_table_meta_t *meta;
    idx_t remaining;
    idx_t count;
    char err[512];
    if (!info || !output) return;
    err[0] = '\0';
    state = (rducks_r_table_state_t *)duckdb_function_get_init_data(info);
    meta = state ? state->meta : NULL;
    if (!state || !meta) {
        duckdb_function_set_error(info, "Rducks table state is missing");
        duckdb_data_chunk_set_size(output, 0);
        return;
    }
    if (!state->evaluated && !rducks_r_table_evaluate_once(state, err, sizeof(err))) {
        duckdb_function_set_error(info, err[0] ? err : "Rducks table R function failed");
        duckdb_data_chunk_set_size(output, 0);
        return;
    }
    if (state->pos >= state->rows) {
        duckdb_data_chunk_set_size(output, 0);
        return;
    }

    remaining = state->rows - state->pos;
    count = remaining < meta->chunk_size ? remaining : meta->chunk_size;
    for (size_t col = 0; col < meta->column_count; col++) {
        duckdb_vector vector = duckdb_data_chunk_get_vector(output, (idx_t)col);
        rducks_rc_direct_vector_view_t view;
        rducks_rc_direct_output_view_init(&view, vector);
        for (idx_t row = 0; row < count; row++) {
            int ok = 1;
            SEXP value = PROTECT(rducks_rc_vector_value_at(state->columns[col], state->pos + row, &ok));
            if (!ok || !rducks_rc_write_direct_output(meta->column_descs[col], &view, row, value, err, sizeof(err))) {
                UNPROTECT(1);
                duckdb_function_set_error(info, err[0] ? err : "failed to write Rducks table output value");
                duckdb_data_chunk_set_size(output, 0);
                return;
            }
            UNPROTECT(1);
        }
    }
    state->pos += count;
    duckdb_data_chunk_set_size(output, count);
}

static bool rducks_register_r_table(rducks_runtime_entry_t *runtime, const char *name, SEXP eval_ref,
                                    const char *columns_spec, const char *column_names_spec,
                                    uint64_t chunk_size, char *err, size_t err_cap) {
    rducks_type_desc_t **column_descs = NULL;
    char **column_names = NULL;
    size_t column_count = 0;
    size_t name_count = 0;
    rducks_r_table_meta_t *meta = NULL;
    duckdb_table_function fn = NULL;
    duckdb_state rc;

    if (!rducks_allow_calling_thread_r_execution(runtime, err, err_cap)) return false;
    rducks_preserved_release_drain_on_main(runtime);
    if (!runtime || !runtime->connection || !name || !name[0] || !Rf_isFunction(eval_ref)) {
        snprintf(err, err_cap, "invalid Rducks table registration request");
        return false;
    }
    if (!rducks_parse_type_list(columns_spec, &column_descs, &column_count, err, err_cap)) return false;
    if (!rducks_parse_table_column_names(column_names_spec, &column_names, &name_count, err, err_cap)) {
        for (size_t i = 0; i < column_count; i++) rducks_type_desc_destroy(column_descs[i]);
        free(column_descs);
        return false;
    }
    if (column_count == 0 || column_count != name_count) {
        snprintf(err, err_cap, "Rducks table column names and types must have the same non-zero length");
        for (size_t i = 0; i < column_count; i++) rducks_type_desc_destroy(column_descs[i]);
        free(column_descs);
        for (size_t i = 0; i < name_count; i++) free(column_names[i]);
        free(column_names);
        return false;
    }
    if (chunk_size < 1U || chunk_size > RDUCKS_TABLE_DEFAULT_CHUNK_SIZE) {
        snprintf(err, err_cap, "Rducks table chunk_size must be between 1 and %llu",
                 (unsigned long long)RDUCKS_TABLE_DEFAULT_CHUNK_SIZE);
        for (size_t i = 0; i < column_count; i++) rducks_type_desc_destroy(column_descs[i]);
        free(column_descs);
        for (size_t i = 0; i < name_count; i++) free(column_names[i]);
        free(column_names);
        return false;
    }

    meta = (rducks_r_table_meta_t *)rducks_calloc_array(1, sizeof(*meta));
    fn = duckdb_create_table_function();
    if (!meta || !fn) {
        snprintf(err, err_cap, "failed to allocate DuckDB table function for Rducks table UDF");
        if (fn) duckdb_destroy_table_function(&fn);
        if (meta) free(meta);
        for (size_t i = 0; i < column_count; i++) rducks_type_desc_destroy(column_descs[i]);
        free(column_descs);
        for (size_t i = 0; i < name_count; i++) free(column_names[i]);
        free(column_names);
        return false;
    }
    meta->fun = R_NilValue;
    meta->name = rducks_strdup(name);
    if (!meta->name) {
        snprintf(err, err_cap, "out of memory copying Rducks table function name");
        duckdb_destroy_table_function(&fn);
        free(meta);
        for (size_t i = 0; i < column_count; i++) rducks_type_desc_destroy(column_descs[i]);
        free(column_descs);
        for (size_t i = 0; i < name_count; i++) free(column_names[i]);
        free(column_names);
        return false;
    }
    meta->runtime = runtime;
    meta->column_count = column_count;
    meta->column_names = column_names;
    meta->column_descs = column_descs;
    meta->chunk_size = (idx_t)chunk_size;
    column_names = NULL;
    column_descs = NULL;
    R_PreserveObject(eval_ref);
    meta->fun = eval_ref;

    duckdb_table_function_set_name(fn, name);
    duckdb_table_function_set_extra_info(fn, meta, rducks_r_table_meta_destroy);
    duckdb_table_function_set_bind(fn, rducks_r_table_bind);
    duckdb_table_function_set_init(fn, rducks_r_table_init);
    duckdb_table_function_set_function(fn, rducks_r_table_function);
    rc = duckdb_register_table_function(runtime->connection, fn);
    duckdb_destroy_table_function(&fn);
    if (rc != DuckDBSuccess) {
        snprintf(err, err_cap, "DuckDB failed to register Rducks table function %s", name);
        rducks_r_table_meta_destroy(meta);
        return false;
    }
    return true;
}

static void rducks_register_table_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    duckdb_string_t *names = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 0));
    duckdb_string_t *evaluator_ids = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 1));
    duckdb_string_t *evaluator_tokens = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 2));
    duckdb_string_t *columns_specs = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 3));
    duckdb_string_t *column_names_specs = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 4));
    uint64_t *chunk_sizes = (uint64_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 5));
    bool *out = (bool *)duckdb_vector_get_data(output);
    if (!runtime) {
        duckdb_scalar_function_set_error(info, "Rducks runtime is not initialized for this connection");
        return;
    }

    for (idx_t i = 0; i < n; i++) {
        char *name = rducks_copy_duckdb_string(&names[i]);
        char *evaluator_id = rducks_copy_duckdb_string(&evaluator_ids[i]);
        char *evaluator_token = rducks_copy_duckdb_string(&evaluator_tokens[i]);
        char *columns_spec = rducks_copy_duckdb_string(&columns_specs[i]);
        char *column_names_spec = rducks_copy_duckdb_string(&column_names_specs[i]);
        char err[512];
        SEXP eval_ref = R_NilValue;
        err[0] = '\0';
        if (!name || !evaluator_id || !evaluator_token || !columns_spec || !column_names_spec) {
            free(name);
            free(evaluator_id);
            free(evaluator_token);
            free(columns_spec);
            free(column_names_spec);
            duckdb_scalar_function_set_error(info, "out of memory");
            return;
        }
        if (!rducks_allow_calling_thread_r_execution(runtime, err, sizeof(err)) ||
            !rducks_lookup_evaluator_ref(evaluator_id, evaluator_token, &eval_ref, err, sizeof(err))) {
            free(name);
            free(evaluator_id);
            free(evaluator_token);
            free(columns_spec);
            free(column_names_spec);
            duckdb_scalar_function_set_error(info, err[0] ? err : "invalid Rducks evaluator handle");
            return;
        }
        out[i] = rducks_register_r_table(runtime, name, eval_ref, columns_spec, column_names_spec,
                                         chunk_sizes[i], err, sizeof(err));
        free(name);
        free(evaluator_id);
        free(evaluator_token);
        free(columns_spec);
        free(column_names_spec);
        if (!out[i]) {
            duckdb_scalar_function_set_error(info, err[0] ? err : "Rducks table registration failed");
            return;
        }
    }
}
