/* Included by ../rducks_extension.c. */

static void rducks_arrow_error_to_buffer(duckdb_error_data error_data, const char *fallback,
                                         char *err_msg, size_t err_cap) {
    const char *msg = NULL;
    if (error_data && duckdb_error_data_has_error(error_data)) {
        msg = duckdb_error_data_message(error_data);
    }
    snprintf(err_msg, err_cap, "%s", (msg && msg[0]) ? msg : fallback);
}

static int rducks_allocate_arrow_options(rducks_runtime_entry_t *runtime,
                                         duckdb_arrow_options *out_options, int *borrowed,
                                         char *err_msg, size_t err_cap) {
    duckdb_arrow_options options = NULL;
    if (!runtime || !runtime->connection) {
        snprintf(err_msg, err_cap, "Rducks runtime has no DuckDB connection for Arrow C Data conversion");
        return 0;
    }
    if (!out_options || !borrowed) return 0;
    *out_options = NULL;
    *borrowed = 0;

    duckdb_connection_get_arrow_options(runtime->connection, &options);
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

static void rducks_release_arrow_schema_if_set(struct ArrowSchema *schema) {
    if (schema && schema->release) {
        schema->release(schema);
        schema->release = NULL;
    }
}

static void rducks_release_arrow_array_if_set(struct ArrowArray *array) {
    if (array && array->release) {
        array->release(array);
        array->release = NULL;
    }
}

static int rducks_fill_arrow_schema_native(rducks_runtime_entry_t *runtime, struct ArrowSchema *schema,
                                           rducks_type_desc_t **descs, size_t count,
                                           const char **names, char *err_msg, size_t err_cap) {
    duckdb_arrow_options options = NULL;
    int borrowed_options = 0;
    duckdb_logical_type *types = NULL;
    duckdb_error_data error_data = NULL;

    if (!schema) {
        snprintf(err_msg, err_cap, "invalid Arrow schema output pointer");
        return 0;
    }

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

    if (!rducks_allocate_arrow_options(runtime, &options, &borrowed_options, err_msg, err_cap)) {
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
            rducks_release_arrow_schema_if_set(schema);
            return 0;
        }
        duckdb_destroy_error_data(&error_data);
    }
    return 1;
}

static int rducks_fill_arrow_schema(rducks_runtime_entry_t *runtime, SEXP schema_xptr,
                                    rducks_type_desc_t **descs, size_t count,
                                    const char **names, char *err_msg, size_t err_cap) {
    return rducks_fill_arrow_schema_native(runtime, nanoarrow_output_schema_from_xptr(schema_xptr), descs, count, names,
                                          err_msg, err_cap);
}

static int rducks_fill_input_arrow_schema_native(rducks_runtime_entry_t *runtime, struct ArrowSchema *schema,
                                                 rducks_r_scalar_meta_t *meta,
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

    ok = rducks_fill_arrow_schema_native(runtime, schema, meta->args, meta->arity, names, err_msg, err_cap);
    if (owned_names) {
        for (size_t i = 0; i < meta->arity; i++) free(owned_names[i]);
    }
    free(owned_names);
    free(names);
    return ok;
}

static int rducks_fill_input_arrow_schema(rducks_runtime_entry_t *runtime, SEXP schema_xptr,
                                          rducks_r_scalar_meta_t *meta,
                                          char *err_msg, size_t err_cap) {
    return rducks_fill_input_arrow_schema_native(runtime, nanoarrow_output_schema_from_xptr(schema_xptr), meta, err_msg, err_cap);
}

static int rducks_fill_output_arrow_schema_native(rducks_runtime_entry_t *runtime, struct ArrowSchema *schema,
                                                  rducks_r_scalar_meta_t *meta,
                                                  char *err_msg, size_t err_cap) {
    rducks_type_desc_t *descs[1];
    const char *names[1];
    descs[0] = meta->return_desc;
    names[0] = "result";
    return rducks_fill_arrow_schema_native(runtime, schema, descs, 1, names, err_msg, err_cap);
}

static int rducks_fill_output_arrow_schema(rducks_runtime_entry_t *runtime, SEXP schema_xptr,
                                           rducks_r_scalar_meta_t *meta,
                                           char *err_msg, size_t err_cap) {
    return rducks_fill_output_arrow_schema_native(runtime, nanoarrow_output_schema_from_xptr(schema_xptr), meta, err_msg, err_cap);
}

static int rducks_fill_input_arrow_array_native(rducks_runtime_entry_t *runtime, struct ArrowArray *array,
                                                duckdb_data_chunk input,
                                                char *err_msg, size_t err_cap) {
    duckdb_arrow_options options = NULL;
    int borrowed_options = 0;
    duckdb_error_data error_data = NULL;

    if (!array) {
        snprintf(err_msg, err_cap, "invalid Arrow array output pointer");
        return 0;
    }

    if (!rducks_allocate_arrow_options(runtime, &options, &borrowed_options, err_msg, err_cap)) {
        return 0;
    }

    error_data = duckdb_data_chunk_to_arrow(options, input, array);
    rducks_release_arrow_options(&options, borrowed_options);
    if (error_data) {
        int has_error = duckdb_error_data_has_error(error_data);
        if (has_error) {
            rducks_arrow_error_to_buffer(error_data, "DuckDB failed to export input chunk to Arrow C Data", err_msg, err_cap);
            duckdb_destroy_error_data(&error_data);
            rducks_release_arrow_array_if_set(array);
            return 0;
        }
        duckdb_destroy_error_data(&error_data);
    }
    return 1;
}

static int rducks_fill_input_arrow_array(rducks_runtime_entry_t *runtime, SEXP array_xptr,
                                         duckdb_data_chunk input,
                                         char *err_msg, size_t err_cap) {
    return rducks_fill_input_arrow_array_native(runtime, nanoarrow_output_array_from_xptr(array_xptr), input, err_msg, err_cap);
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
    (void)return_desc;
    if (count == 0) return 1;
    if (count > (idx_t)UINT32_MAX) {
        snprintf(err_msg, err_cap, "Arrow result chunk is too large to copy into DuckDB output");
        return 0;
    }
    duckdb_selection_vector sel = duckdb_create_selection_vector(count);
    if (!sel) {
        snprintf(err_msg, err_cap, "failed to allocate DuckDB selection vector for Arrow result copy");
        return 0;
    }
    /* Copy the imported Arrow result into DuckDB's callback-owned output vector
     * before destroying the temporary imported chunk below. This deliberately
     * avoids relying on duckdb_vector_reference_vector() lifetime semantics for
     * vectors owned by a soon-to-be-destroyed data chunk.
     */
    sel_t *sel_data = duckdb_selection_vector_get_data_ptr(sel);
    for (idx_t i = 0; i < count; i++) sel_data[i] = (sel_t)i;
    duckdb_vector_copy_sel(imported, output, sel, count, 0, 0);
    duckdb_destroy_selection_vector(sel);
    return 1;
}

static int rducks_import_arrow_result_native(rducks_runtime_entry_t *runtime,
                                             struct ArrowArray *result_array, struct ArrowSchema *result_schema,
                                             rducks_type_desc_t *return_desc, idx_t expected_size,
                                             duckdb_vector output, char *err_msg, size_t err_cap) {
    duckdb_arrow_converted_schema converted_schema = NULL;
    duckdb_data_chunk result_chunk = NULL;
    duckdb_error_data error_data = NULL;
    idx_t result_size;

    if (!runtime || !runtime->connection) {
        snprintf(err_msg, err_cap, "Rducks runtime has no DuckDB connection for Arrow C Data import");
        return 0;
    }
    if (!result_array || !result_schema || result_array->release == NULL || result_schema->release == NULL) {
        snprintf(err_msg, err_cap, "Rducks nanoarrow scalar wrapper returned invalid Arrow C Data");
        return 0;
    }
    if (result_array->length != (int64_t)expected_size) {
        snprintf(err_msg, err_cap, "Rducks nanoarrow scalar adapter returned %lld rows, expected %llu",
                 (long long)result_array->length, (unsigned long long)expected_size);
        return 0;
    }

    error_data = duckdb_schema_from_arrow(runtime->connection, result_schema, &converted_schema);
    if (error_data) {
        int has_error = duckdb_error_data_has_error(error_data);
        if (has_error) {
            rducks_arrow_error_to_buffer(error_data, "DuckDB failed to import Arrow C Data result schema", err_msg, err_cap);
            duckdb_destroy_error_data(&error_data);
            return 0;
        }
        duckdb_destroy_error_data(&error_data);
    }

    error_data = duckdb_data_chunk_from_arrow(runtime->connection, result_array, converted_schema, &result_chunk);
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

static int rducks_import_arrow_result(rducks_runtime_entry_t *runtime, SEXP result_array_xptr,
                                      SEXP output_schema_xptr, rducks_type_desc_t *return_desc,
                                      idx_t expected_size, duckdb_vector output, char *err_msg, size_t err_cap) {
    struct ArrowArray *result_array;
    struct ArrowSchema *result_schema;
    SEXP result_schema_xptr;

    if (!Rf_inherits(result_array_xptr, "nanoarrow_array")) {
        snprintf(err_msg, err_cap, "Rducks nanoarrow scalar wrapper must return a nanoarrow_array");
        return 0;
    }

    result_array = nanoarrow_array_from_xptr(result_array_xptr);
    result_schema_xptr = rducks_arrow_array_schema_xptr(result_array_xptr, output_schema_xptr);
    result_schema = nanoarrow_schema_from_xptr(result_schema_xptr);
    return rducks_import_arrow_result_native(runtime, result_array, result_schema, return_desc, expected_size, output,
                                            err_msg, err_cap);
}

/* In-process single-thread R evaluator phases. These still use R/nanoarrow
 * external pointers and therefore must run on the recorded R thread. Future
 * concurrent_inproc or serialized backends should replace the prepare/evaluate
 * boundary with owned native buffers or Arrow IPC payloads before crossing
 * threads/processes.
 */
static int rducks_r_scalar_prepare_inprocess_arrow(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta, duckdb_data_chunk input,
                                                   SEXP *input_schema_xptr, SEXP *input_array_xptr,
                                                   SEXP *output_schema_xptr, idx_t *n,
                                                   int *protect_count, char *err_msg, size_t err_cap) {
    *n = duckdb_data_chunk_get_size(input);

    *input_schema_xptr = PROTECT(nanoarrow_schema_owning_xptr());
    (*protect_count)++;
    if (!rducks_fill_input_arrow_schema(runtime, *input_schema_xptr, meta, err_msg, err_cap)) return 0;

    *input_array_xptr = PROTECT(nanoarrow_array_owning_xptr());
    (*protect_count)++;
    if (!rducks_fill_input_arrow_array(runtime, *input_array_xptr, input, err_msg, err_cap)) return 0;
    R_SetExternalPtrTag(*input_array_xptr, *input_schema_xptr);

    *output_schema_xptr = PROTECT(nanoarrow_schema_owning_xptr());
    (*protect_count)++;
    if (!rducks_fill_output_arrow_schema(runtime, *output_schema_xptr, meta, err_msg, err_cap)) return 0;
    return 1;
}

static SEXP rducks_r_scalar_eval_arrow_on_r_thread(rducks_r_scalar_meta_t *meta,
                                                   SEXP input_array_xptr, SEXP input_schema_xptr,
                                                   SEXP output_schema_xptr, idx_t n,
                                                   int *protect_count, int *r_err) {
    SEXP n_sexp = PROTECT(Rf_ScalarReal((double)n));
    (*protect_count)++;
    SEXP call = PROTECT(Rf_lang5(meta->fun, input_array_xptr, input_schema_xptr, output_schema_xptr, n_sexp));
    (*protect_count)++;
    SEXP result = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, r_err));
    (*protect_count)++;
    return result;
}

static int rducks_r_scalar_result_is_error(SEXP result, char *err_msg, size_t err_cap) {
    if (!Rf_inherits(result, "rducks_arrow_error")) return 0;
    if (TYPEOF(result) == STRSXP && XLENGTH(result) > 0 && STRING_ELT(result, 0) != NA_STRING) {
        snprintf(err_msg, err_cap, "%s", CHAR(STRING_ELT(result, 0)));
    } else {
        snprintf(err_msg, err_cap, "Rducks nanoarrow R function or marshal error");
    }
    return 1;
}

static int rducks_r_scalar_emit_arrow_result(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta, SEXP result,
                                             SEXP output_schema_xptr, idx_t n,
                                             duckdb_vector output, char *err_msg, size_t err_cap) {
    if (rducks_r_scalar_result_is_error(result, err_msg, err_cap)) return 0;
    return rducks_import_arrow_result(runtime, result, output_schema_xptr, meta->return_desc, n, output, err_msg, err_cap);
}

static SEXP rducks_named_list_get(SEXP x, const char *name) {
    SEXP names;
    R_xlen_t n;
    if (!x || TYPEOF(x) != VECSXP || !name) return R_NilValue;
    names = Rf_getAttrib(x, R_NamesSymbol);
    if (TYPEOF(names) != STRSXP) return R_NilValue;
    n = XLENGTH(x);
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP nm = STRING_ELT(names, i);
        if (nm != NA_STRING && strcmp(CHAR(nm), name) == 0) return VECTOR_ELT(x, i);
    }
    return R_NilValue;
}

static int rducks_ripc_bundle_valid(SEXP bundle) {
    return TYPEOF(bundle) == VECSXP &&
           Rf_isFunction(rducks_named_list_get(bundle, "execute")) &&
           Rf_isFunction(rducks_named_list_get(bundle, "submit")) &&
           Rf_isFunction(rducks_named_list_get(bundle, "collect")) &&
           Rf_isFunction(rducks_named_list_get(bundle, "collect_many"));
}

static SEXP rducks_ripc_call_submit_on_r_thread(rducks_r_scalar_meta_t *meta,
                                                SEXP input_array_xptr, SEXP input_schema_xptr,
                                                SEXP output_schema_xptr, idx_t n,
                                                int *protect_count, int *r_err) {
    SEXP submit = rducks_named_list_get(meta->fun, "submit");
    SEXP n_sexp = PROTECT(Rf_ScalarReal((double)n));
    (*protect_count)++;
    SEXP call = PROTECT(Rf_lang5(submit, input_array_xptr, input_schema_xptr, output_schema_xptr, n_sexp));
    (*protect_count)++;
    SEXP result = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, r_err));
    (*protect_count)++;
    return result;
}

static SEXP rducks_ripc_call_collect_on_r_thread(rducks_r_scalar_meta_t *meta,
                                                 SEXP future, SEXP output_schema_xptr, idx_t n,
                                                 int *protect_count, int *r_err) {
    SEXP collect = rducks_named_list_get(meta->fun, "collect");
    SEXP n_sexp = PROTECT(Rf_ScalarReal((double)n));
    (*protect_count)++;
    SEXP call = PROTECT(Rf_lang4(collect, future, output_schema_xptr, n_sexp));
    (*protect_count)++;
    SEXP result = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, r_err));
    (*protect_count)++;
    return result;
}

static SEXP rducks_ripc_call_collect_many_on_r_thread(rducks_r_scalar_meta_t *meta,
                                                      SEXP futures, SEXP output_schemas, SEXP ns,
                                                      int *protect_count, int *r_err) {
    SEXP collect_many = rducks_named_list_get(meta->fun, "collect_many");
    SEXP call = PROTECT(Rf_lang4(collect_many, futures, output_schemas, ns));
    (*protect_count)++;
    SEXP result = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, r_err));
    (*protect_count)++;
    return result;
}

static void rducks_ripc_release_preserved(SEXP *future, SEXP *output_schema_xptr) {
    if (future && *future && *future != R_NilValue) {
        R_ReleaseObject(*future);
        *future = R_NilValue;
    }
    if (output_schema_xptr && *output_schema_xptr && *output_schema_xptr != R_NilValue) {
        R_ReleaseObject(*output_schema_xptr);
        *output_schema_xptr = R_NilValue;
    }
}

static int rducks_ripc_submit_chunk_on_main_impl(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                                 duckdb_data_chunk input,
                                                 SEXP *future_out, SEXP *output_schema_out, idx_t *n_out,
                                                 char *err_msg, size_t err_cap) {
    idx_t n = 0;
    int protect_count = 0;
    int r_err = 0;
    SEXP input_schema_xptr = R_NilValue;
    SEXP input_array_xptr = R_NilValue;
    SEXP output_schema_xptr = R_NilValue;
    SEXP future = R_NilValue;

    if (!runtime || !meta || !future_out || !output_schema_out || !n_out) {
        snprintf(err_msg, err_cap, "Rducks RIPC submit request is missing state");
        return 0;
    }
    if (!rducks_is_main_thread(runtime)) {
        snprintf(err_msg, err_cap, "Rducks RIPC Future submission reached a non-main thread");
        return 0;
    }
    if (!rducks_ripc_bundle_valid(meta->fun)) {
        snprintf(err_msg, err_cap, "Rducks RIPC metadata bundle is invalid");
        return 0;
    }

    rducks_udf_record_evaluator(meta, duckdb_data_chunk_get_size(input));

    if (!rducks_r_scalar_prepare_inprocess_arrow(runtime, meta, input, &input_schema_xptr, &input_array_xptr,
                                                 &output_schema_xptr, &n, &protect_count, err_msg, err_cap)) {
        goto fail;
    }

    future = rducks_ripc_call_submit_on_r_thread(meta, input_array_xptr, input_schema_xptr,
                                                 output_schema_xptr, n, &protect_count, &r_err);
    if (r_err) {
        snprintf(err_msg, err_cap, "Rducks Future Arrow IPC submit failed");
        goto fail;
    }
    if (rducks_r_scalar_result_is_error(future, err_msg, err_cap)) goto fail;

    R_PreserveObject(future);
    *future_out = future;
    R_PreserveObject(output_schema_xptr);
    *output_schema_out = output_schema_xptr;
    rducks_udf_record_ripc_inflight_add(meta);
    *n_out = n;
    UNPROTECT(protect_count);
    return 1;

fail:
    UNPROTECT(protect_count);
    return 0;
}

typedef struct rducks_ripc_submit_context {
    rducks_runtime_entry_t *runtime;
    rducks_r_scalar_meta_t *meta;
    duckdb_data_chunk input;
    SEXP *future_out;
    SEXP *output_schema_out;
    idx_t *n_out;
    char *err_msg;
    size_t err_cap;
    int ok;
} rducks_ripc_submit_context_t;

static void rducks_ripc_set_fallback_error(char *err_msg, size_t err_cap, const char *fallback) {
    if (err_msg && err_cap > 0U && !err_msg[0]) snprintf(err_msg, err_cap, "%s", fallback);
}

static SEXP rducks_ripc_submit_unwind_body(void *data) {
    rducks_ripc_submit_context_t *ctx = (rducks_ripc_submit_context_t *)data;
    ctx->ok = rducks_ripc_submit_chunk_on_main_impl(ctx->runtime, ctx->meta, ctx->input,
                                                    ctx->future_out, ctx->output_schema_out,
                                                    ctx->n_out, ctx->err_msg, ctx->err_cap);
    return R_NilValue;
}

static void rducks_ripc_submit_unwind_cleanup(void *data, Rboolean jump) {
    rducks_ripc_submit_context_t *ctx = (rducks_ripc_submit_context_t *)data;
    if (jump) {
        ctx->ok = 0;
        rducks_ripc_release_preserved(ctx->future_out, ctx->output_schema_out);
        rducks_ripc_set_fallback_error(ctx->err_msg, ctx->err_cap,
                                       "Rducks Future Arrow IPC submit failed");
    }
}

static SEXP rducks_ripc_submit_try_body(void *data) {
    return R_UnwindProtect(rducks_ripc_submit_unwind_body, data,
                           rducks_ripc_submit_unwind_cleanup, data,
                           NULL);
}

static SEXP rducks_ripc_submit_error_handler(SEXP condition, void *data) {
    (void)condition;
    rducks_ripc_submit_context_t *ctx = (rducks_ripc_submit_context_t *)data;
    ctx->ok = 0;
    rducks_ripc_release_preserved(ctx->future_out, ctx->output_schema_out);
    rducks_ripc_set_fallback_error(ctx->err_msg, ctx->err_cap,
                                   "Rducks Future Arrow IPC submit failed");
    return R_NilValue;
}

static int rducks_ripc_submit_chunk_on_main(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                            duckdb_data_chunk input,
                                            SEXP *future_out, SEXP *output_schema_out, idx_t *n_out,
                                            char *err_msg, size_t err_cap) {
    rducks_ripc_submit_context_t ctx;
    memset(&ctx, 0, sizeof(ctx));
    if (future_out) *future_out = R_NilValue;
    if (output_schema_out) *output_schema_out = R_NilValue;
    if (err_msg && err_cap > 0U) err_msg[0] = '\0';
    ctx.runtime = runtime;
    ctx.meta = meta;
    ctx.input = input;
    ctx.future_out = future_out;
    ctx.output_schema_out = output_schema_out;
    ctx.n_out = n_out;
    ctx.err_msg = err_msg;
    ctx.err_cap = err_cap;
    (void)R_tryCatchError(rducks_ripc_submit_try_body, &ctx,
                          rducks_ripc_submit_error_handler, &ctx);
    return ctx.ok;
}

static int rducks_ripc_collect_chunk_on_main_impl(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                                  SEXP future, SEXP output_schema_xptr, idx_t n,
                                                  duckdb_vector output, char *err_msg, size_t err_cap) {
    int protect_count = 0;
    int r_err = 0;
    SEXP result = R_NilValue;
    if (!runtime || !meta || !future || future == R_NilValue || !output_schema_xptr || output_schema_xptr == R_NilValue) {
        snprintf(err_msg, err_cap, "Rducks RIPC collect request is missing state");
        return 0;
    }
    if (!rducks_is_main_thread(runtime)) {
        snprintf(err_msg, err_cap, "Rducks RIPC Future collection reached a non-main thread");
        return 0;
    }
    result = rducks_ripc_call_collect_on_r_thread(meta, future, output_schema_xptr, n, &protect_count, &r_err);
    if (r_err) {
        snprintf(err_msg, err_cap, "Rducks Future Arrow IPC collect failed");
        goto fail;
    }
    if (!rducks_r_scalar_emit_arrow_result(runtime, meta, result, output_schema_xptr, n, output, err_msg, err_cap)) goto fail;
    rducks_udf_record_ripc_inflight_done(meta, 1U);
    UNPROTECT(protect_count);
    return 1;
fail:
    rducks_udf_record_ripc_inflight_done(meta, 1U);
    UNPROTECT(protect_count);
    return 0;
}

typedef struct rducks_ripc_collect_context {
    rducks_runtime_entry_t *runtime;
    rducks_r_scalar_meta_t *meta;
    SEXP *future_slot;
    SEXP *output_schema_slot;
    idx_t n;
    duckdb_vector output;
    char *err_msg;
    size_t err_cap;
    int ok;
    int inflight_active;
} rducks_ripc_collect_context_t;

static SEXP rducks_ripc_collect_unwind_body(void *data) {
    rducks_ripc_collect_context_t *ctx = (rducks_ripc_collect_context_t *)data;
    SEXP future = ctx->future_slot ? *ctx->future_slot : R_NilValue;
    SEXP output_schema_xptr = ctx->output_schema_slot ? *ctx->output_schema_slot : R_NilValue;
    ctx->ok = rducks_ripc_collect_chunk_on_main_impl(ctx->runtime, ctx->meta, future,
                                                     output_schema_xptr, ctx->n,
                                                     ctx->output, ctx->err_msg, ctx->err_cap);
    ctx->inflight_active = 0;
    return R_NilValue;
}

static void rducks_ripc_collect_unwind_cleanup(void *data, Rboolean jump) {
    rducks_ripc_collect_context_t *ctx = (rducks_ripc_collect_context_t *)data;
    if (jump) {
        ctx->ok = 0;
        if (ctx->inflight_active) {
            rducks_udf_record_ripc_inflight_done(ctx->meta, 1U);
            ctx->inflight_active = 0;
        }
        rducks_ripc_release_preserved(ctx->future_slot, ctx->output_schema_slot);
        rducks_ripc_set_fallback_error(ctx->err_msg, ctx->err_cap,
                                       "Rducks Future Arrow IPC collect failed");
    }
}

static SEXP rducks_ripc_collect_try_body(void *data) {
    return R_UnwindProtect(rducks_ripc_collect_unwind_body, data,
                           rducks_ripc_collect_unwind_cleanup, data,
                           NULL);
}

static SEXP rducks_ripc_collect_error_handler(SEXP condition, void *data) {
    (void)condition;
    rducks_ripc_collect_context_t *ctx = (rducks_ripc_collect_context_t *)data;
    ctx->ok = 0;
    rducks_ripc_set_fallback_error(ctx->err_msg, ctx->err_cap,
                                   "Rducks Future Arrow IPC collect failed");
    return R_NilValue;
}

static int rducks_ripc_collect_chunk_on_main(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                             SEXP *future_slot, SEXP *output_schema_slot, idx_t n,
                                             duckdb_vector output, char *err_msg, size_t err_cap) {
    rducks_ripc_collect_context_t ctx;
    memset(&ctx, 0, sizeof(ctx));
    if (err_msg && err_cap > 0U) err_msg[0] = '\0';
    ctx.runtime = runtime;
    ctx.meta = meta;
    ctx.future_slot = future_slot;
    ctx.output_schema_slot = output_schema_slot;
    ctx.n = n;
    ctx.inflight_active = 1;
    ctx.output = output;
    ctx.err_msg = err_msg;
    ctx.err_cap = err_cap;
    (void)R_tryCatchError(rducks_ripc_collect_try_body, &ctx,
                          rducks_ripc_collect_error_handler, &ctx);
    return ctx.ok;
}

static int rducks_ripc_execute(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                               duckdb_data_chunk input, duckdb_vector output,
                               char *err_msg, size_t err_cap) {
    SEXP future = R_NilValue;
    SEXP output_schema_xptr = R_NilValue;
    idx_t n = 0;
    int ok;
    if (!rducks_ripc_submit_chunk_on_main(runtime, meta, input, &future, &output_schema_xptr, &n, err_msg, err_cap)) {
        rducks_ripc_release_preserved(&future, &output_schema_xptr);
        return 0;
    }
    ok = rducks_ripc_collect_chunk_on_main(runtime, meta, &future, &output_schema_xptr, n, output, err_msg, err_cap);
    rducks_ripc_release_preserved(&future, &output_schema_xptr);
    return ok;
}

static int rducks_r_scalar_execute_impl(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta, duckdb_data_chunk input, duckdb_vector output,
                                        char *err_msg, size_t err_cap) {
    idx_t n = 0;
    int protect_count = 0;
    int r_err = 0;
    SEXP input_schema_xptr = R_NilValue;
    SEXP input_array_xptr = R_NilValue;
    SEXP output_schema_xptr = R_NilValue;
    SEXP result = R_NilValue;

    if (!meta || !meta->fun || meta->fun == R_NilValue) {
        snprintf(err_msg, err_cap, "Rducks scalar metadata missing");
        return 0;
    }
    rducks_udf_record_evaluator(meta, duckdb_data_chunk_get_size(input));

    if (!rducks_r_scalar_prepare_inprocess_arrow(runtime, meta, input, &input_schema_xptr, &input_array_xptr,
                                                 &output_schema_xptr, &n, &protect_count, err_msg, err_cap)) {
        goto fail;
    }

    result = rducks_r_scalar_eval_arrow_on_r_thread(meta, input_array_xptr, input_schema_xptr,
                                                    output_schema_xptr, n, &protect_count, &r_err);
    if (r_err) {
        snprintf(err_msg, err_cap, "Rducks nanoarrow R function or marshal error");
        goto fail;
    }

    if (!rducks_r_scalar_emit_arrow_result(runtime, meta, result, output_schema_xptr, n, output, err_msg, err_cap)) goto fail;

    UNPROTECT(protect_count);
    return 1;

fail:
    UNPROTECT(protect_count);
    return 0;
}

typedef struct rducks_arrow_execute_context {
    rducks_runtime_entry_t *runtime;
    rducks_r_scalar_meta_t *meta;
    duckdb_data_chunk input;
    duckdb_vector output;
    char *err_msg;
    size_t err_cap;
    const char *fallback_error;
    int ok;
} rducks_arrow_execute_context_t;

static void rducks_arrow_set_fallback_error(rducks_arrow_execute_context_t *ctx) {
    if (ctx && ctx->err_msg && ctx->err_cap > 0U && !ctx->err_msg[0] && ctx->fallback_error) {
        snprintf(ctx->err_msg, ctx->err_cap, "%s", ctx->fallback_error);
    }
}

static SEXP rducks_r_scalar_execute_unwind_body(void *data) {
    rducks_arrow_execute_context_t *ctx = (rducks_arrow_execute_context_t *)data;
    ctx->ok = rducks_r_scalar_execute_impl(ctx->runtime, ctx->meta, ctx->input,
                                           ctx->output, ctx->err_msg, ctx->err_cap);
    return R_NilValue;
}

static void rducks_arrow_execute_unwind_cleanup(void *data, Rboolean jump) {
    rducks_arrow_execute_context_t *ctx = (rducks_arrow_execute_context_t *)data;
    if (jump) {
        ctx->ok = 0;
        rducks_arrow_set_fallback_error(ctx);
    }
}

static SEXP rducks_r_scalar_execute_try_body(void *data) {
    return R_UnwindProtect(rducks_r_scalar_execute_unwind_body, data,
                           rducks_arrow_execute_unwind_cleanup, data,
                           NULL);
}

static SEXP rducks_arrow_execute_error_handler(SEXP condition, void *data) {
    (void)condition;
    rducks_arrow_execute_context_t *ctx = (rducks_arrow_execute_context_t *)data;
    ctx->ok = 0;
    rducks_arrow_set_fallback_error(ctx);
    return R_NilValue;
}

static int rducks_r_scalar_execute(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                   duckdb_data_chunk input, duckdb_vector output,
                                   char *err_msg, size_t err_cap) {
    rducks_arrow_execute_context_t ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.runtime = runtime;
    ctx.meta = meta;
    ctx.input = input;
    ctx.output = output;
    ctx.err_msg = err_msg;
    ctx.err_cap = err_cap;
    ctx.fallback_error = "Rducks nanoarrow R function or marshal error";
    if (err_msg && err_cap > 0U) err_msg[0] = '\0';
    (void)R_tryCatchError(rducks_r_scalar_execute_try_body, &ctx,
                          rducks_arrow_execute_error_handler, &ctx);
    return ctx.ok;
}

static void rducks_r_scalar_udf(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_r_scalar_meta_t *meta = (rducks_r_scalar_meta_t *)duckdb_scalar_function_get_extra_info(info);
    rducks_runtime_entry_t *runtime = rducks_runtime_from_function_info(info, meta);
    char err_msg[256];
    err_msg[0] = '\0';

    if (!runtime) {
        duckdb_scalar_function_set_error(info, "Rducks scalar UDF is missing per-connection runtime state");
        return;
    }

    if (!rducks_is_main_thread(runtime)) {
        if (rducks_concurrent_inproc_enabled(runtime)) {
            rducks_udf_record_dispatch(meta, duckdb_data_chunk_get_size(input), 1);
            if (!rducks_queue_submit_scalar(runtime, meta, input, output, err_msg, sizeof(err_msg))) {
                duckdb_scalar_function_set_error(info, err_msg[0] ? err_msg : "Rducks queued scalar R function failed");
            }
            return;
        }
        if (rducks_multiprocess_parallel_enabled(runtime) && meta && meta->eval_mode == RDUCKS_EVAL_RIPC) {
            rducks_udf_record_dispatch(meta, duckdb_data_chunk_get_size(input), 1);
            if (!rducks_queue_submit_scalar(runtime, meta, input, output, err_msg, sizeof(err_msg))) {
                duckdb_scalar_function_set_error(info, err_msg[0] ? err_msg : "Rducks queued Future Arrow IPC UDF failed");
            }
            return;
        }
        duckdb_scalar_function_set_error(
            info,
            "Rducks scalar UDF reached a non-calling DuckDB execution thread; use rducks_enable(con, threads = 'single') "
            "for the direct R API execution path, or call rducks_enable_inproc() after registration to enable the queued backend"
        );
        return;
    }

    rducks_preserved_release_drain_on_main(runtime);

    if (rducks_multiprocess_parallel_enabled(runtime) && meta && meta->eval_mode == RDUCKS_EVAL_RIPC) {
        rducks_udf_record_dispatch(meta, duckdb_data_chunk_get_size(input), 1);
        if (!rducks_queue_submit_ripc_cooperative_on_main(runtime, meta, input, output, err_msg, sizeof(err_msg))) {
            duckdb_scalar_function_set_error(info, err_msg[0] ? err_msg : "Rducks cooperative Future Arrow IPC UDF failed");
        }
        return;
    }

    if (rducks_concurrent_inproc_enabled(runtime)) {
        rducks_udf_record_dispatch(meta, duckdb_data_chunk_get_size(input), 0);
        if (!rducks_queue_execute_scalar_inline_on_main(runtime, meta, input, output, err_msg, sizeof(err_msg))) {
            duckdb_scalar_function_set_error(info, err_msg[0] ? err_msg : "Rducks main-thread scalar R function failed");
        }
        return;
    }

    rducks_udf_record_dispatch(meta, duckdb_data_chunk_get_size(input), 0);

    if (meta && meta->eval_mode == RDUCKS_EVAL_RC) {
        if (!rducks_rc_scalar_execute(runtime, meta, input, output, err_msg, sizeof(err_msg))) {
            duckdb_scalar_function_set_error(info, err_msg[0] ? err_msg : "Rducks RC scalar R function failed");
            return;
        }
        return;
    }

    if (meta && meta->eval_mode == RDUCKS_EVAL_RCV) {
        /* Reached only after the non-main-thread guard above. RCV materializes
         * DuckDB vectors into R objects and calls the R function, so it must run
         * on the recorded main R thread or through the queued main-thread path.
         */
        if (!rducks_rc_vectorized_execute(runtime, meta, input, output, err_msg, sizeof(err_msg))) {
            duckdb_scalar_function_set_error(info, err_msg[0] ? err_msg : "Rducks RC vectorized R function failed");
            return;
        }
        return;
    }

    if (meta && meta->eval_mode == RDUCKS_EVAL_RIPC) {
        if (!rducks_ripc_execute(runtime, meta, input, output, err_msg, sizeof(err_msg))) {
            duckdb_scalar_function_set_error(info, err_msg[0] ? err_msg : "Rducks Future Arrow IPC R function failed");
            return;
        }
        return;
    }

    if (!rducks_r_scalar_execute(runtime, meta, input, output, err_msg, sizeof(err_msg))) {
        duckdb_scalar_function_set_error(info, err_msg[0] ? err_msg : "Rducks scalar R function failed");
        return;
    }
}

