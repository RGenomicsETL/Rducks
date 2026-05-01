/* Included by ../rducks_extension.c. */

static void rducks_arrow_error_to_buffer(duckdb_error_data error_data, const char *fallback,
                                         char *err_msg, size_t err_cap) {
    const char *msg = NULL;
    if (error_data && duckdb_error_data_has_error(error_data)) {
        msg = duckdb_error_data_message(error_data);
    }
    snprintf(err_msg, err_cap, "%s", (msg && msg[0]) ? msg : fallback);
}

static int rducks_allocate_arrow_options(duckdb_arrow_options *out_options, int *borrowed,
                                         char *err_msg, size_t err_cap) {
    duckdb_arrow_options options = NULL;
    if (!out_options || !borrowed) return 0;
    *out_options = NULL;
    *borrowed = 0;

    duckdb_connection_get_arrow_options(g_connection, &options);
    if (options) {
        *out_options = options;
        return 1;
    }

    snprintf(err_msg, err_cap, "failed to get DuckDB Arrow C Data options");
    return 0;
}

static void rducks_release_arrow_options(duckdb_arrow_options *options, int borrowed) {
    if (!borrowed && options && *options) duckdb_destroy_arrow_options(options);
}

static int rducks_fill_arrow_schema(SEXP schema_xptr, rducks_type_desc_t **descs, size_t count,
                                    const char **names, char *err_msg, size_t err_cap) {
    duckdb_arrow_options options = NULL;
    int borrowed_options = 0;
    duckdb_logical_type *types = NULL;
    duckdb_error_data error_data = NULL;
    struct ArrowSchema *schema = nanoarrow_output_schema_from_xptr(schema_xptr);

    if (count > 0) {
        types = (duckdb_logical_type *)calloc(count, sizeof(duckdb_logical_type));
        if (!types) {
            snprintf(err_msg, err_cap, "out of memory allocating nanoarrow schema type list");
            return 0;
        }
        for (size_t i = 0; i < count; i++) {
            types[i] = rducks_create_logical_type_for_desc(descs[i]);
            if (!types[i]) {
                snprintf(err_msg, err_cap, "failed to allocate DuckDB logical type for nanoarrow schema");
                for (size_t j = 0; j < count; j++) {
                    if (types[j]) duckdb_destroy_logical_type(&types[j]);
                }
                free(types);
                return 0;
            }
        }
    }

    if (!rducks_allocate_arrow_options(&options, &borrowed_options, err_msg, err_cap)) {
        for (size_t i = 0; i < count; i++) {
            if (types[i]) duckdb_destroy_logical_type(&types[i]);
        }
        free(types);
        return 0;
    }

    error_data = duckdb_to_arrow_schema(options, types, names, (idx_t)count, schema);
    rducks_release_arrow_options(&options, borrowed_options);
    for (size_t i = 0; i < count; i++) {
        if (types[i]) duckdb_destroy_logical_type(&types[i]);
    }
    free(types);

    if (error_data) {
        int has_error = duckdb_error_data_has_error(error_data);
        if (has_error) {
            rducks_arrow_error_to_buffer(error_data, "DuckDB failed to create Arrow C Data schema", err_msg, err_cap);
            duckdb_destroy_error_data(&error_data);
            return 0;
        }
        duckdb_destroy_error_data(&error_data);
    }
    return 1;
}

static int rducks_fill_input_arrow_schema(SEXP schema_xptr, rducks_r_scalar_meta_t *meta,
                                          char *err_msg, size_t err_cap) {
    const char **names = NULL;
    char **owned_names = NULL;
    int ok;
    if (meta->arity > 0) {
        names = (const char **)calloc(meta->arity, sizeof(char *));
        owned_names = (char **)calloc(meta->arity, sizeof(char *));
        if (!names || !owned_names) {
            free(names);
            free(owned_names);
            snprintf(err_msg, err_cap, "out of memory allocating nanoarrow schema names");
            return 0;
        }
        for (size_t i = 0; i < meta->arity; i++) {
            char buf[32];
            snprintf(buf, sizeof(buf), "arg%zu", i + 1U);
            owned_names[i] = rducks_strdup_len(buf, strlen(buf));
            if (!owned_names[i]) {
                for (size_t j = 0; j < i; j++) free(owned_names[j]);
                free(owned_names);
                free(names);
                snprintf(err_msg, err_cap, "out of memory allocating nanoarrow schema name");
                return 0;
            }
            names[i] = owned_names[i];
        }
    }

    ok = rducks_fill_arrow_schema(schema_xptr, meta->args, meta->arity, names, err_msg, err_cap);
    if (owned_names) {
        for (size_t i = 0; i < meta->arity; i++) free(owned_names[i]);
    }
    free(owned_names);
    free(names);
    return ok;
}

static int rducks_fill_output_arrow_schema(SEXP schema_xptr, rducks_r_scalar_meta_t *meta,
                                           char *err_msg, size_t err_cap) {
    rducks_type_desc_t *descs[1];
    const char *names[1];
    descs[0] = meta->return_desc;
    names[0] = "result";
    return rducks_fill_arrow_schema(schema_xptr, descs, 1, names, err_msg, err_cap);
}

static int rducks_fill_input_arrow_array(SEXP array_xptr, duckdb_data_chunk input,
                                         char *err_msg, size_t err_cap) {
    duckdb_arrow_options options = NULL;
    int borrowed_options = 0;
    duckdb_error_data error_data = NULL;
    struct ArrowArray *array = nanoarrow_output_array_from_xptr(array_xptr);

    if (!rducks_allocate_arrow_options(&options, &borrowed_options, err_msg, err_cap)) {
        return 0;
    }

    error_data = duckdb_data_chunk_to_arrow(options, input, array);
    rducks_release_arrow_options(&options, borrowed_options);
    if (error_data) {
        int has_error = duckdb_error_data_has_error(error_data);
        if (has_error) {
            rducks_arrow_error_to_buffer(error_data, "DuckDB failed to export input chunk to Arrow C Data", err_msg, err_cap);
            duckdb_destroy_error_data(&error_data);
            return 0;
        }
        duckdb_destroy_error_data(&error_data);
    }
    return 1;
}

static SEXP rducks_arrow_array_schema_xptr(SEXP array_xptr, SEXP fallback_schema_xptr) {
    SEXP schema_xptr = R_ExternalPtrTag(array_xptr);
    if (schema_xptr == R_NilValue) return fallback_schema_xptr;
    if (!Rf_inherits(schema_xptr, "nanoarrow_schema")) return fallback_schema_xptr;
    return schema_xptr;
}

static int rducks_copy_imported_result_vector(rducks_type_desc_t *return_desc, duckdb_vector imported,
                                              duckdb_vector output, idx_t count,
                                              char *err_msg, size_t err_cap) {
    if (return_desc && return_desc->kind == RDUCKS_KIND_ENUM) {
        duckdb_selection_vector sel = duckdb_create_selection_vector(count);
        if (!sel) {
            snprintf(err_msg, err_cap, "failed to allocate DuckDB selection vector for enum result copy");
            return 0;
        }
        sel_t *sel_data = duckdb_selection_vector_get_data_ptr(sel);
        for (idx_t i = 0; i < count; i++) sel_data[i] = (sel_t)i;
        duckdb_vector_copy_sel(imported, output, sel, count, 0, 0);
        duckdb_destroy_selection_vector(sel);
        return 1;
    }
    duckdb_vector_reference_vector(output, imported);
    return 1;
}

static int rducks_import_arrow_result(SEXP result_array_xptr, SEXP output_schema_xptr, rducks_type_desc_t *return_desc,
                                      idx_t expected_size, duckdb_vector output, char *err_msg, size_t err_cap) {
    struct ArrowArray *result_array;
    struct ArrowSchema *result_schema;
    SEXP result_schema_xptr;
    duckdb_arrow_converted_schema converted_schema = NULL;
    duckdb_data_chunk result_chunk = NULL;
    duckdb_error_data error_data = NULL;
    idx_t result_size;

    if (!Rf_inherits(result_array_xptr, "nanoarrow_array")) {
        snprintf(err_msg, err_cap, "Rducks nanoarrow scalar wrapper must return a nanoarrow_array");
        return 0;
    }

    result_array = nanoarrow_array_from_xptr(result_array_xptr);
    if (result_array->length != (int64_t)expected_size) {
        snprintf(err_msg, err_cap, "Rducks nanoarrow scalar adapter returned %lld rows, expected %llu",
                 (long long)result_array->length, (unsigned long long)expected_size);
        return 0;
    }

    result_schema_xptr = rducks_arrow_array_schema_xptr(result_array_xptr, output_schema_xptr);
    result_schema = nanoarrow_schema_from_xptr(result_schema_xptr);

    error_data = duckdb_schema_from_arrow(g_connection, result_schema, &converted_schema);
    if (error_data) {
        int has_error = duckdb_error_data_has_error(error_data);
        if (has_error) {
            rducks_arrow_error_to_buffer(error_data, "DuckDB failed to import Arrow C Data result schema", err_msg, err_cap);
            duckdb_destroy_error_data(&error_data);
            return 0;
        }
        duckdb_destroy_error_data(&error_data);
    }

    error_data = duckdb_data_chunk_from_arrow(g_connection, result_array, converted_schema, &result_chunk);
    if (error_data) {
        int has_error = duckdb_error_data_has_error(error_data);
        if (has_error) {
            rducks_arrow_error_to_buffer(error_data, "DuckDB failed to import Arrow C Data result chunk", err_msg, err_cap);
            duckdb_destroy_error_data(&error_data);
            duckdb_destroy_arrow_converted_schema(&converted_schema);
            return 0;
        }
        duckdb_destroy_error_data(&error_data);
    }

    if (!result_chunk) {
        snprintf(err_msg, err_cap, "DuckDB returned no result chunk for nanoarrow scalar result");
        duckdb_destroy_arrow_converted_schema(&converted_schema);
        return 0;
    }
    result_size = duckdb_data_chunk_get_size(result_chunk);
    if (result_size != expected_size) {
        snprintf(err_msg, err_cap, "DuckDB imported %llu Arrow C Data result rows, expected %llu",
                 (unsigned long long)result_size, (unsigned long long)expected_size);
        duckdb_destroy_data_chunk(&result_chunk);
        duckdb_destroy_arrow_converted_schema(&converted_schema);
        return 0;
    }

    if (!rducks_copy_imported_result_vector(return_desc, duckdb_data_chunk_get_vector(result_chunk, 0), output,
                                            result_size, err_msg, err_cap)) {
        duckdb_destroy_data_chunk(&result_chunk);
        duckdb_destroy_arrow_converted_schema(&converted_schema);
        return 0;
    }
    duckdb_destroy_data_chunk(&result_chunk);
    duckdb_destroy_arrow_converted_schema(&converted_schema);
    return 1;
}

static int rducks_r_scalar_execute(rducks_r_scalar_meta_t *meta, duckdb_data_chunk input, duckdb_vector output,
                                   char *err_msg, size_t err_cap) {
    idx_t n;
    int protect_count = 0;
    int r_err = 0;
    SEXP input_schema_xptr;
    SEXP input_array_xptr;
    SEXP output_schema_xptr;
    SEXP n_sexp;
    SEXP call;
    SEXP result;

    rducks_stats_note_r_execute(rducks_is_main_thread());
    if (!meta || !meta->fun || meta->fun == R_NilValue) {
        snprintf(err_msg, err_cap, "Rducks scalar metadata missing");
        return 0;
    }
    n = duckdb_data_chunk_get_size(input);

    input_schema_xptr = PROTECT(nanoarrow_schema_owning_xptr());
    protect_count++;
    if (!rducks_fill_input_arrow_schema(input_schema_xptr, meta, err_msg, err_cap)) goto fail;

    input_array_xptr = PROTECT(nanoarrow_array_owning_xptr());
    protect_count++;
    if (!rducks_fill_input_arrow_array(input_array_xptr, input, err_msg, err_cap)) goto fail;
    R_SetExternalPtrTag(input_array_xptr, input_schema_xptr);

    output_schema_xptr = PROTECT(nanoarrow_schema_owning_xptr());
    protect_count++;
    if (!rducks_fill_output_arrow_schema(output_schema_xptr, meta, err_msg, err_cap)) goto fail;

    n_sexp = PROTECT(Rf_ScalarReal((double)n));
    protect_count++;
    call = PROTECT(Rf_lang5(meta->fun, input_array_xptr, input_schema_xptr, output_schema_xptr, n_sexp));
    protect_count++;
    result = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, &r_err));
    protect_count++;

    if (r_err) {
        snprintf(err_msg, err_cap, "Rducks nanoarrow R function or marshal error");
        goto fail;
    }

    if (Rf_inherits(result, "rducks_arrow_error")) {
        if (TYPEOF(result) == STRSXP && XLENGTH(result) > 0 && STRING_ELT(result, 0) != NA_STRING) {
            snprintf(err_msg, err_cap, "%s", CHAR(STRING_ELT(result, 0)));
        } else {
            snprintf(err_msg, err_cap, "Rducks nanoarrow R function or marshal error");
        }
        goto fail;
    }

    if (!rducks_import_arrow_result(result, output_schema_xptr, meta->return_desc, n, output, err_msg, err_cap)) goto fail;

    UNPROTECT(protect_count);
    return 1;

fail:
    UNPROTECT(protect_count);
    return 0;
}

static void rducks_r_scalar_udf(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_r_scalar_meta_t *meta = (rducks_r_scalar_meta_t *)duckdb_scalar_function_get_extra_info(info);
    char err_msg[256];
    err_msg[0] = '\0';

    int is_main_thread = rducks_is_main_thread();
    rducks_stats_note_udf_entry(is_main_thread);

    if (is_main_thread) {
        rducks_drain_worker_requests();
        if (!rducks_r_scalar_execute(meta, input, output, err_msg, sizeof(err_msg))) {
            duckdb_scalar_function_set_error(info, err_msg[0] ? err_msg : "Rducks scalar R function failed");
            return;
        }
        rducks_drain_worker_requests();
        return;
    }

    rducks_udf_request_t req;
    req.meta = meta;
    req.input = input;
    req.output = output;
    rducks_request_enqueue_and_wait(&req);
    if (!req.ok) {
        duckdb_scalar_function_set_error(info, req.err[0] ? req.err : "Rducks main-thread R execution request failed");
    }
}

