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
        snprintf(err_msg, err_cap, "invalid Rducks query stream token request");
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
        snprintf(err_msg, err_cap, "out of memory allocating Rducks query stream token");
        return 0;
    }
    return 1;
}

static int rducks_query_stream_capture_schema(rducks_query_stream_entry_t *entry,
                                              char *err_msg, size_t err_cap) {
    if (!entry) {
        snprintf(err_msg, err_cap, "invalid Rducks query stream schema state");
        return 0;
    }
    entry->column_count = duckdb_column_count(&entry->result);
    if (entry->column_count == 0) return 1;

    entry->types = (duckdb_logical_type *)rducks_calloc_array((size_t)entry->column_count, sizeof(*entry->types));
    entry->names = (char **)rducks_calloc_array((size_t)entry->column_count, sizeof(*entry->names));
    if (!entry->types || !entry->names) {
        snprintf(err_msg, err_cap, "out of memory allocating Rducks query stream schema");
        return 0;
    }

    for (idx_t i = 0; i < entry->column_count; i++) {
        const char *name = duckdb_column_name(&entry->result, i);
        entry->names[i] = rducks_strdup(name ? name : "");
        entry->types[i] = duckdb_column_logical_type(&entry->result, i);
        if (!entry->names[i] || !entry->types[i]) {
            snprintf(err_msg, err_cap, "failed to copy Rducks query stream schema");
            return 0;
        }
    }
    return 1;
}

static SEXP rducks_qs_named_list(int n, const char **names, int *protect_count) {
    SEXP out = PROTECT(Rf_allocVector(VECSXP, n));
    SEXP nms = PROTECT(Rf_allocVector(STRSXP, n));
    (*protect_count) += 2;
    for (int i = 0; i < n; i++) SET_STRING_ELT(nms, i, Rf_mkChar(names[i]));
    Rf_setAttrib(out, R_NamesSymbol, nms);
    return out;
}

static int rducks_qs_set_string(SEXP list, int i, const char *value) {
    SET_VECTOR_ELT(list, i, Rf_mkString(value ? value : ""));
    return 1;
}

static const char *rducks_query_stream_scalar_token(duckdb_type type_id) {
    switch (type_id) {
    case DUCKDB_TYPE_BOOLEAN: return "bool";
    case DUCKDB_TYPE_TINYINT: return "i8";
    case DUCKDB_TYPE_UTINYINT: return "u8";
    case DUCKDB_TYPE_SMALLINT: return "i16";
    case DUCKDB_TYPE_USMALLINT: return "u16";
    case DUCKDB_TYPE_INTEGER: return "i32";
    case DUCKDB_TYPE_UINTEGER: return "u32";
    case DUCKDB_TYPE_BIGINT: return "i64";
    case DUCKDB_TYPE_UBIGINT: return "u64";
    case DUCKDB_TYPE_FLOAT: return "f32";
    case DUCKDB_TYPE_DOUBLE: return "f64";
    case DUCKDB_TYPE_VARCHAR: return "varchar";
    case DUCKDB_TYPE_BLOB: return "blob";
    case DUCKDB_TYPE_DATE: return "date";
    case DUCKDB_TYPE_TIME: return "time";
    case DUCKDB_TYPE_TIMESTAMP: return "timestamp";
    case DUCKDB_TYPE_HUGEINT: return "hugeint";
    case DUCKDB_TYPE_UHUGEINT: return "uhugeint";
    case DUCKDB_TYPE_UUID: return "uuid";
    case DUCKDB_TYPE_INTERVAL: return "interval";
    case DUCKDB_TYPE_BIT: return "bit";
    default: return NULL;
    }
}

static int rducks_query_stream_type_spec_from_logical(duckdb_logical_type type, SEXP *out,
                                                       int *protect_count, char *err_msg, size_t err_cap);

static int rducks_query_stream_list_like_spec(const char *kind, duckdb_logical_type child_type,
                                               idx_t array_size, SEXP *out, int *protect_count,
                                               char *err_msg, size_t err_cap) {
    const char *names[] = {"kind", "child", "size"};
    SEXP spec;
    SEXP child_spec = R_NilValue;
    spec = rducks_qs_named_list(strcmp(kind, "array") == 0 ? 3 : 2, names, protect_count);
    rducks_qs_set_string(spec, 0, kind);
    if (!rducks_query_stream_type_spec_from_logical(child_type, &child_spec, protect_count, err_msg, err_cap)) return 0;
    SET_VECTOR_ELT(spec, 1, child_spec);
    if (strcmp(kind, "array") == 0) {
        if (array_size > (idx_t)INT_MAX) {
            snprintf(err_msg, err_cap, "DuckDB ARRAY size is too large for Rducks query stream materialization");
            return 0;
        }
        SET_VECTOR_ELT(spec, 2, Rf_ScalarInteger((int)array_size));
    }
    *out = spec;
    return 1;
}

static int rducks_query_stream_struct_like_spec(const char *kind, duckdb_logical_type type,
                                                 SEXP *out, int *protect_count,
                                                 char *err_msg, size_t err_cap) {
    const char *spec_names[] = {"kind", "names", "children"};
    idx_t count = strcmp(kind, "union") == 0 ? duckdb_union_type_member_count(type) : duckdb_struct_type_child_count(type);
    SEXP spec = rducks_qs_named_list(3, spec_names, protect_count);
    SEXP r_names = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)count));
    SEXP children = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)count));
    (*protect_count) += 2;
    rducks_qs_set_string(spec, 0, kind);
    for (idx_t i = 0; i < count; i++) {
        char *child_name = strcmp(kind, "union") == 0 ? duckdb_union_type_member_name(type, i) : duckdb_struct_type_child_name(type, i);
        duckdb_logical_type child_type = strcmp(kind, "union") == 0 ? duckdb_union_type_member_type(type, i) : duckdb_struct_type_child_type(type, i);
        SEXP child_spec = R_NilValue;
        if (!child_name || !child_type) {
            if (child_name) duckdb_free(child_name);
            if (child_type) duckdb_destroy_logical_type(&child_type);
            snprintf(err_msg, err_cap, "failed to inspect DuckDB %s child type", kind);
            return 0;
        }
        SET_STRING_ELT(r_names, (R_xlen_t)i, Rf_mkChar(child_name));
        duckdb_free(child_name);
        if (!rducks_query_stream_type_spec_from_logical(child_type, &child_spec, protect_count, err_msg, err_cap)) {
            duckdb_destroy_logical_type(&child_type);
            return 0;
        }
        duckdb_destroy_logical_type(&child_type);
        SET_VECTOR_ELT(children, (R_xlen_t)i, child_spec);
    }
    SET_VECTOR_ELT(spec, 1, r_names);
    SET_VECTOR_ELT(spec, 2, children);
    *out = spec;
    return 1;
}

static int rducks_query_stream_type_spec_from_logical(duckdb_logical_type type, SEXP *out,
                                                       int *protect_count, char *err_msg, size_t err_cap) {
    duckdb_type type_id;
    const char *token;
    if (!type || !out) {
        snprintf(err_msg, err_cap, "invalid DuckDB logical type in query stream schema");
        return 0;
    }
    *out = R_NilValue;
    type_id = duckdb_get_type_id(type);
    token = rducks_query_stream_scalar_token(type_id);
    if (token) {
        const char *names[] = {"kind", "token"};
        SEXP spec = rducks_qs_named_list(2, names, protect_count);
        rducks_qs_set_string(spec, 0, "scalar");
        rducks_qs_set_string(spec, 1, token);
        *out = spec;
        return 1;
    }

    switch (type_id) {
    case DUCKDB_TYPE_SQLNULL: {
        const char *names[] = {"kind"};
        SEXP spec = rducks_qs_named_list(1, names, protect_count);
        rducks_qs_set_string(spec, 0, "null");
        *out = spec;
        return 1;
    }
    case DUCKDB_TYPE_DECIMAL: {
        const char *names[] = {"kind", "width", "scale"};
        SEXP spec = rducks_qs_named_list(3, names, protect_count);
        rducks_qs_set_string(spec, 0, "decimal");
        SET_VECTOR_ELT(spec, 1, Rf_ScalarInteger((int)duckdb_decimal_width(type)));
        SET_VECTOR_ELT(spec, 2, Rf_ScalarInteger((int)duckdb_decimal_scale(type)));
        *out = spec;
        return 1;
    }
    case DUCKDB_TYPE_ENUM: {
        const char *names[] = {"kind", "levels"};
        uint32_t count = duckdb_enum_dictionary_size(type);
        SEXP spec = rducks_qs_named_list(2, names, protect_count);
        SEXP levels = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)count));
        (*protect_count)++;
        rducks_qs_set_string(spec, 0, "enum");
        for (uint32_t i = 0; i < count; i++) {
            char *value = duckdb_enum_dictionary_value(type, (idx_t)i);
            if (!value) {
                snprintf(err_msg, err_cap, "failed to inspect DuckDB ENUM value");
                return 0;
            }
            SET_STRING_ELT(levels, (R_xlen_t)i, Rf_mkChar(value));
            duckdb_free(value);
        }
        SET_VECTOR_ELT(spec, 1, levels);
        *out = spec;
        return 1;
    }
    case DUCKDB_TYPE_LIST: {
        duckdb_logical_type child = duckdb_list_type_child_type(type);
        int ok;
        if (!child) {
            snprintf(err_msg, err_cap, "failed to inspect DuckDB LIST child type");
            return 0;
        }
        ok = rducks_query_stream_list_like_spec("list", child, 0, out, protect_count, err_msg, err_cap);
        duckdb_destroy_logical_type(&child);
        return ok;
    }
    case DUCKDB_TYPE_ARRAY: {
        duckdb_logical_type child = duckdb_array_type_child_type(type);
        idx_t size = duckdb_array_type_array_size(type);
        int ok;
        if (!child) {
            snprintf(err_msg, err_cap, "failed to inspect DuckDB ARRAY child type");
            return 0;
        }
        ok = rducks_query_stream_list_like_spec("array", child, size, out, protect_count, err_msg, err_cap);
        duckdb_destroy_logical_type(&child);
        return ok;
    }
    case DUCKDB_TYPE_MAP: {
        const char *names[] = {"kind", "key", "value"};
        duckdb_logical_type key_type = duckdb_map_type_key_type(type);
        duckdb_logical_type value_type = duckdb_map_type_value_type(type);
        SEXP spec;
        SEXP key_spec = R_NilValue;
        SEXP value_spec = R_NilValue;
        if (!key_type || !value_type) {
            if (key_type) duckdb_destroy_logical_type(&key_type);
            if (value_type) duckdb_destroy_logical_type(&value_type);
            snprintf(err_msg, err_cap, "failed to inspect DuckDB MAP type");
            return 0;
        }
        spec = rducks_qs_named_list(3, names, protect_count);
        rducks_qs_set_string(spec, 0, "map");
        if (!rducks_query_stream_type_spec_from_logical(key_type, &key_spec, protect_count, err_msg, err_cap) ||
            !rducks_query_stream_type_spec_from_logical(value_type, &value_spec, protect_count, err_msg, err_cap)) {
            duckdb_destroy_logical_type(&key_type);
            duckdb_destroy_logical_type(&value_type);
            return 0;
        }
        duckdb_destroy_logical_type(&key_type);
        duckdb_destroy_logical_type(&value_type);
        SET_VECTOR_ELT(spec, 1, key_spec);
        SET_VECTOR_ELT(spec, 2, value_spec);
        *out = spec;
        return 1;
    }
    case DUCKDB_TYPE_STRUCT:
        return rducks_query_stream_struct_like_spec("struct", type, out, protect_count, err_msg, err_cap);
    case DUCKDB_TYPE_UNION:
        return rducks_query_stream_struct_like_spec("union", type, out, protect_count, err_msg, err_cap);
    default:
        snprintf(err_msg, err_cap, "unsupported DuckDB query stream column type id %d", (int)type_id);
        return 0;
    }
}

static int rducks_query_stream_type_specs(rducks_query_stream_entry_t *entry, SEXP *out,
                                          int *protect_count, char *err_msg, size_t err_cap) {
    SEXP specs;
    if (!entry || !out) return 0;
    specs = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)entry->column_count));
    (*protect_count)++;
    for (idx_t i = 0; i < entry->column_count; i++) {
        SEXP spec = R_NilValue;
        if (!rducks_query_stream_type_spec_from_logical(entry->types[i], &spec, protect_count, err_msg, err_cap)) return 0;
        SET_VECTOR_ELT(specs, (R_xlen_t)i, spec);
    }
    *out = specs;
    return 1;
}

static SEXP rducks_query_stream_column_names(rducks_query_stream_entry_t *entry, int *protect_count) {
    SEXP names = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)entry->column_count));
    (*protect_count)++;
    for (idx_t i = 0; i < entry->column_count; i++) {
        SET_STRING_ELT(names, (R_xlen_t)i, Rf_mkChar(entry->names[i] ? entry->names[i] : ""));
    }
    return names;
}

static int rducks_query_stream_fill_arrow_schema(rducks_runtime_entry_t *runtime,
                                                 rducks_query_stream_entry_t *entry,
                                                 struct ArrowSchema *schema,
                                                 char *err_msg, size_t err_cap) {
    duckdb_arrow_options options = NULL;
    int borrowed_options = 0;
    duckdb_error_data error_data = NULL;
    const char **names = NULL;
    int ok = 0;

    (void)runtime;
    if (!entry || !schema) {
        snprintf(err_msg, err_cap, "invalid Rducks query stream Arrow schema request");
        return 0;
    }
    if (!entry->connection) {
        snprintf(err_msg, err_cap, "Rducks query stream has no DuckDB connection for Arrow schema conversion");
        return 0;
    }
    if (!rducks_allocate_arrow_options_for_connection(entry->connection, &options, &borrowed_options, err_msg, err_cap)) return 0;
    if (entry->column_count > 0) {
        names = (const char **)rducks_calloc_array((size_t)entry->column_count, sizeof(*names));
        if (!names) {
            snprintf(err_msg, err_cap, "out of memory allocating Rducks query stream Arrow names");
            goto cleanup;
        }
        for (idx_t i = 0; i < entry->column_count; i++) names[i] = entry->names[i] ? entry->names[i] : "";
    }

    error_data = duckdb_to_arrow_schema(options, entry->types, names, entry->column_count, schema);
    if (error_data) {
        int has_error = duckdb_error_data_has_error(error_data);
        if (has_error) {
            rducks_arrow_error_to_buffer(error_data, "DuckDB failed to create query stream Arrow schema", err_msg, err_cap);
            duckdb_destroy_error_data(&error_data);
            rducks_release_arrow_schema_if_set(schema);
            goto cleanup;
        }
        duckdb_destroy_error_data(&error_data);
    }
    ok = 1;
cleanup:
    free(names);
    rducks_release_arrow_options(&options, borrowed_options);
    return ok;
}

static int rducks_query_stream_cache_r_metadata(rducks_runtime_entry_t *runtime,
                                                rducks_query_stream_entry_t *entry,
                                                char *err_msg, size_t err_cap) {
    int protect_count = 0;
    SEXP schema_xptr = R_NilValue;
    SEXP type_specs = R_NilValue;
    SEXP column_names = R_NilValue;

    if (!runtime || !entry) {
        snprintf(err_msg, err_cap, "invalid Rducks query stream metadata state");
        return 0;
    }
    if (!rducks_allow_calling_thread_r_execution(runtime, err_msg, err_cap)) return 0;

    schema_xptr = PROTECT(nanoarrow_schema_owning_xptr());
    protect_count++;
    if (!rducks_query_stream_fill_arrow_schema(runtime, entry, nanoarrow_output_schema_from_xptr(schema_xptr),
                                               err_msg, err_cap)) {
        goto error;
    }
    if (!rducks_query_stream_type_specs(entry, &type_specs, &protect_count, err_msg, err_cap)) goto error;
    column_names = rducks_query_stream_column_names(entry, &protect_count);

    R_PreserveObject(schema_xptr);
    R_PreserveObject(type_specs);
    R_PreserveObject(column_names);
    entry->schema_xptr = schema_xptr;
    entry->type_specs = type_specs;
    entry->column_names_sexp = column_names;
    UNPROTECT(protect_count);
    return 1;

error:
    if (protect_count > 0) UNPROTECT(protect_count);
    return 0;
}

static void rducks_query_stream_r_error(SEXP err_obj, const char *fallback, char *err_msg, size_t err_cap) {
    int r_err = 0;
    const char *cur_error;
    if (!err_msg || err_cap == 0U) return;
    snprintf(err_msg, err_cap, "%s", fallback ? fallback : "Rducks query stream R materialization error");
    cur_error = R_curErrorBuf();
    if (cur_error && cur_error[0]) {
        snprintf(err_msg, err_cap, "%s: %s", fallback ? fallback : "Rducks query stream R materialization error", cur_error);
        return;
    }
    if (!err_obj || err_obj == R_NilValue) return;
    if (TYPEOF(err_obj) == STRSXP && XLENGTH(err_obj) > 0 && STRING_ELT(err_obj, 0) != NA_STRING) {
        snprintf(err_msg, err_cap, "%s: %s", fallback ? fallback : "Rducks query stream R materialization error",
                 CHAR(STRING_ELT(err_obj, 0)));
        return;
    }
    SEXP call = PROTECT(Rf_lang2(Rf_install("conditionMessage"), err_obj));
    SEXP msg = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, &r_err));
    if (!r_err && TYPEOF(msg) == STRSXP && XLENGTH(msg) > 0 && STRING_ELT(msg, 0) != NA_STRING) {
        snprintf(err_msg, err_cap, "%s: %s", fallback ? fallback : "Rducks query stream R materialization error",
                 CHAR(STRING_ELT(msg, 0)));
    }
    UNPROTECT(2);
}

static int rducks_query_stream_store_chunk(rducks_runtime_entry_t *runtime,
                                           rducks_query_stream_entry_t *entry,
                                           duckdb_data_chunk chunk,
                                           char *err_msg, size_t err_cap) {
    int protect_count = 0;
    int r_err = 0;
    SEXP schema_xptr = R_NilValue;
    SEXP array_xptr = R_NilValue;
    SEXP type_specs = R_NilValue;
    SEXP column_names = R_NilValue;
    SEXP pkg = R_NilValue;
    SEXP ns = R_NilValue;
    SEXP fun = R_NilValue;
    SEXP token = R_NilValue;
    SEXP call = R_NilValue;
    SEXP result = R_NilValue;
    int ok = 0;

    if (!runtime || !entry || !chunk) {
        snprintf(err_msg, err_cap, "invalid Rducks query stream chunk state");
        return 0;
    }
    if (!rducks_allow_calling_thread_r_execution(runtime, err_msg, err_cap)) return 0;
    if (entry->schema_xptr == R_NilValue || entry->type_specs == R_NilValue || entry->column_names_sexp == R_NilValue) {
        snprintf(err_msg, err_cap, "Rducks query stream cached metadata is missing");
        return 0;
    }

    schema_xptr = entry->schema_xptr;
    type_specs = entry->type_specs;
    column_names = entry->column_names_sexp;

    array_xptr = PROTECT(nanoarrow_array_owning_xptr());
    protect_count++;
    if (!entry->connection) {
        snprintf(err_msg, err_cap, "Rducks query stream has no DuckDB connection for Arrow array conversion");
        goto cleanup;
    }
    if (!rducks_fill_input_arrow_array_for_connection(entry->connection, array_xptr, chunk, err_msg, err_cap)) goto cleanup;
    R_SetExternalPtrTag(array_xptr, schema_xptr);

    pkg = PROTECT(Rf_mkString("Rducks"));
    protect_count++;
    ns = PROTECT(R_FindNamespace(pkg));
    protect_count++;
    fun = PROTECT(Rf_findFun(Rf_install("rducks_query_stream_store_arrow_batch"), ns));
    protect_count++;
    token = PROTECT(Rf_mkString(entry->token ? entry->token : ""));
    protect_count++;
    call = PROTECT(Rf_lang6(fun, token, array_xptr, schema_xptr, type_specs, column_names));
    protect_count++;
    result = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, &r_err));
    protect_count++;
    if (r_err) {
        rducks_query_stream_r_error(result, "Rducks query stream materialization failed", err_msg, err_cap);
        goto cleanup;
    }
    if (!Rf_isLogical(result) || XLENGTH(result) != 1 || LOGICAL(result)[0] != TRUE) {
        snprintf(err_msg, err_cap, "Rducks query stream materializer did not acknowledge the batch");
        goto cleanup;
    }
    ok = 1;

cleanup:
    if (protect_count > 0) UNPROTECT(protect_count);
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
        snprintf(err_msg, err_cap, "Rducks runtime has no DuckDB connection for query streaming");
        return 0;
    }
    if (!rducks_allow_calling_thread_r_execution(runtime, err_msg, err_cap)) return 0;
    if (!sql || !sql[0]) {
        snprintf(err_msg, err_cap, "sql must be a non-empty character scalar");
        return 0;
    }

    entry = (rducks_query_stream_entry_t *)calloc(1, sizeof(*entry));
    if (!entry) {
        snprintf(err_msg, err_cap, "out of memory allocating Rducks query stream");
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
        snprintf(err_msg, err_cap, "Rducks supports one active native query stream per connection");
        goto error;
    }
    runtime->query_stream_connection_busy = 1;
    entry->connection = runtime->query_stream_connection;
    rducks_runtime_unlock();

    if (!rducks_query_stream_make_token(runtime, &entry->token, err_msg, err_cap)) goto error;
    rc = duckdb_prepare(entry->connection, sql, &stmt);
    if (rc == DuckDBError) {
        const char *msg = stmt ? duckdb_prepare_error(stmt) : NULL;
        snprintf(err_msg, err_cap, "%s", (msg && msg[0]) ? msg : "DuckDB failed to prepare query stream");
        goto error;
    }

    rc = duckdb_pending_prepared_streaming(stmt, &pending);
    duckdb_destroy_prepare(&stmt);
    stmt = NULL;
    if (rc == DuckDBError) {
        const char *msg = pending ? duckdb_pending_error(pending) : NULL;
        snprintf(err_msg, err_cap, "%s", (msg && msg[0]) ? msg : "DuckDB failed to create pending query stream");
        goto error;
    }

    rc = duckdb_execute_pending(pending, &entry->result);
    entry->result_initialized = 1;
    duckdb_destroy_pending(&pending);
    pending = NULL;
    if (rc == DuckDBError) {
        const char *msg = duckdb_result_error(&entry->result);
        snprintf(err_msg, err_cap, "%s", (msg && msg[0]) ? msg : "DuckDB failed to open query stream");
        goto error;
    }
    if (!duckdb_result_is_streaming(entry->result)) {
        snprintf(err_msg, err_cap, "DuckDB did not create a streaming result for this query");
        goto error;
    }
    if (!rducks_query_stream_capture_schema(entry, err_msg, err_cap)) goto error;
    if (!rducks_query_stream_cache_r_metadata(runtime, entry, err_msg, err_cap)) goto error;

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

static void rducks_query_stream_close_all(rducks_runtime_entry_t *runtime) {
    rducks_query_stream_entry_t *entry;
    if (!runtime) return;
    rducks_runtime_lock();
    entry = runtime->query_streams;
    runtime->query_streams = NULL;
    rducks_runtime_unlock();
    rducks_query_stream_destroy_detached_list(entry);
}

static int rducks_query_stream_schema_native(rducks_runtime_entry_t *runtime, const char *token,
                                             char *err_msg, size_t err_cap) {
    rducks_query_stream_entry_t *entry;
    duckdb_data_chunk chunk = NULL;
    int ok = 0;
    if (!runtime || !token || !token[0]) {
        snprintf(err_msg, err_cap, "invalid Rducks query stream token");
        return 0;
    }

    rducks_runtime_lock();
    entry = rducks_query_stream_find_locked(runtime, token, NULL);
    rducks_runtime_unlock();
    if (!entry) {
        snprintf(err_msg, err_cap, "Rducks query stream is closed");
        return 0;
    }

    chunk = duckdb_create_data_chunk(entry->types, entry->column_count);
    if (!chunk) {
        snprintf(err_msg, err_cap, "failed to allocate empty Rducks query stream schema batch");
        return 0;
    }
    duckdb_data_chunk_set_size(chunk, 0);
    ok = rducks_query_stream_store_chunk(runtime, entry, chunk, err_msg, err_cap);
    duckdb_destroy_data_chunk(&chunk);
    return ok;
}

static int rducks_query_stream_next_native(rducks_runtime_entry_t *runtime, const char *token,
                                           int *has_batch_out, char *err_msg, size_t err_cap) {
    rducks_query_stream_entry_t *entry;
    duckdb_data_chunk chunk = NULL;
    int ok = 0;
    if (has_batch_out) *has_batch_out = 0;
    if (!runtime || !token || !token[0]) {
        snprintf(err_msg, err_cap, "invalid Rducks query stream token");
        return 0;
    }
    if (!rducks_allow_calling_thread_r_execution(runtime, err_msg, err_cap)) return 0;

    rducks_runtime_lock();
    entry = rducks_query_stream_find_locked(runtime, token, NULL);
    if (entry && entry->busy) {
        rducks_runtime_unlock();
        snprintf(err_msg, err_cap, "Rducks query stream is already active");
        return 0;
    }
    if (entry) entry->busy = 1;
    rducks_runtime_unlock();

    if (!entry) {
        snprintf(err_msg, err_cap, "Rducks query stream is closed");
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
            snprintf(err_msg, err_cap, "%s", msg);
            goto cleanup;
        }
        entry->done = 1;
        ok = 1;
        goto cleanup;
    }

    if (!rducks_query_stream_store_chunk(runtime, entry, chunk, err_msg, err_cap)) goto cleanup;
    if (has_batch_out) *has_batch_out = 1;
    ok = 1;

cleanup:
    if (chunk) duckdb_destroy_data_chunk(&chunk);
    rducks_runtime_lock();
    if (entry) entry->busy = 0;
    rducks_runtime_unlock();
    return ok;
}
