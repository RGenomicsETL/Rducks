/* Included by ../rducks_extension.c.
 * No-Arrow native dispatch and disabled legacy surfaces.
 */

static void rducks_noarrow_error(char *err_msg, size_t err_cap, const char *msg) {
    rducks_format_error_message(err_msg, err_cap, "%s", msg);
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

static SEXP rducks_dynamic_arg_tokens_sexp(rducks_r_scalar_meta_t *meta) {
    SEXP out;
    if (!meta || !meta->dynamic_args) return R_NilValue;
    if (meta->arity > (size_t)R_XLEN_T_MAX) return R_NilValue;
    out = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)meta->arity));
    for (size_t i = 0; i < meta->arity; i++) {
        char *token = rducks_type_desc_token(meta->args[i]);
        if (!token) {
            UNPROTECT(1);
            return R_NilValue;
        }
        SET_STRING_ELT(out, (R_xlen_t)i, Rf_mkCharCE(token, CE_UTF8));
        free(token);
    }
    UNPROTECT(1);
    return out;
}

static int rducks_ripc_bundle_valid(SEXP eval_ref) {
    return Rf_isNewList(eval_ref);
}

static int rducks_ripc_configure_meta_on_main(rducks_runtime_entry_t *runtime,
                                              rducks_r_scalar_meta_t *meta,
                                              SEXP eval_ref,
                                              char *err_msg, size_t err_cap) {
    (void)runtime;
    (void)meta;
    (void)eval_ref;
    rducks_noarrow_error(err_msg, err_cap,
                         "Rducks IPC wire execution needs the native Quack adapter and is not enabled in the no-Arrow build");
    return 0;
}

static int rducks_ripc_execute(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                               duckdb_data_chunk input, duckdb_vector output,
                               char *err_msg, size_t err_cap) {
    (void)runtime;
    (void)meta;
    (void)input;
    (void)output;
    rducks_noarrow_error(err_msg, err_cap,
                         "Rducks IPC wire execution needs the native Quack adapter and is not enabled in the no-Arrow build");
    return 0;
}

static int rducks_r_scalar_execute(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                   duckdb_data_chunk input, duckdb_vector output,
                                   char *err_msg, size_t err_cap) {
    (void)runtime;
    (void)meta;
    (void)input;
    (void)output;
    rducks_noarrow_error(err_msg, err_cap,
                         "legacy R evaluator path was removed with the Arrow bridge; use direct in-process marshalling");
    return 0;
}

static int rducks_r_scalar_execute_to_owned_chunk(rducks_runtime_entry_t *runtime,
                                                  rducks_r_scalar_meta_t *meta,
                                                  duckdb_data_chunk input,
                                                  duckdb_vector output,
                                                  duckdb_data_chunk *chunk_out,
                                                  char *err_msg, size_t err_cap) {
    (void)runtime;
    (void)meta;
    (void)input;
    (void)output;
    if (chunk_out) *chunk_out = NULL;
    rducks_noarrow_error(err_msg, err_cap,
                         "legacy queued R result chunks were removed with the Arrow bridge");
    return 0;
}

static void rducks_r_scalar_udf(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_r_scalar_meta_t *meta = (rducks_r_scalar_meta_t *)duckdb_scalar_function_get_extra_info(info);
    rducks_r_scalar_local_state_t *local_state = info ? (rducks_r_scalar_local_state_t *)duckdb_scalar_function_get_state(info) : NULL;
    rducks_r_scalar_meta_t effective_meta_storage;
    rducks_r_scalar_meta_t *exec_meta = meta;
    rducks_runtime_entry_t *runtime = rducks_runtime_from_function_info(info, meta);
    char err_msg[RDUCKS_ERROR_BUFFER_SIZE];
    err_msg[0] = '\0';
    memset(&effective_meta_storage, 0, sizeof(effective_meta_storage));
    rducks_effective_meta_for_state(meta, local_state, &effective_meta_storage, &exec_meta);

    if (!runtime) {
        duckdb_scalar_function_set_error(info, "Rducks scalar UDF is missing per-connection runtime state");
        return;
    }

    if (!exec_meta || (exec_meta->eval_mode != RDUCKS_EVAL_RC && exec_meta->eval_mode != RDUCKS_EVAL_RCV)) {
        duckdb_scalar_function_set_error(info,
            "this no-Arrow build only supports direct RC/RCV scalar-UDF evaluators");
        return;
    }

    if (!rducks_is_main_thread(runtime)) {
        if (rducks_concurrent_inproc_enabled(runtime)) {
            rducks_udf_record_dispatch(meta, duckdb_data_chunk_get_size(input), 1);
            if (!rducks_queue_submit_scalar(runtime, meta, local_state, input, output, err_msg, sizeof(err_msg))) {
                duckdb_scalar_function_set_error(info, err_msg[0] ? err_msg : "Rducks queued direct scalar R function failed");
            }
            return;
        }
        duckdb_scalar_function_set_error(info,
            "Rducks direct scalar UDF reached a non-calling DuckDB execution thread; enable the queued backend or run DuckDB with one thread");
        return;
    }

    rducks_preserved_release_drain_on_main(runtime);

    if (rducks_concurrent_inproc_enabled(runtime)) {
        rducks_udf_record_dispatch(meta, duckdb_data_chunk_get_size(input), 1);
        if (!rducks_queue_submit_scalar_via_worker_on_main(runtime, meta, local_state, input, output, err_msg, sizeof(err_msg))) {
            duckdb_scalar_function_set_error(info, err_msg[0] ? err_msg : "Rducks queued direct scalar R function failed");
        }
        return;
    }

    rducks_udf_record_dispatch(meta, duckdb_data_chunk_get_size(input), 0);
    if (exec_meta->eval_mode == RDUCKS_EVAL_RCV) {
        if (!rducks_rc_vectorized_execute(runtime, exec_meta, input, output, err_msg, sizeof(err_msg))) {
            duckdb_scalar_function_set_error(info, err_msg[0] ? err_msg : "Rducks direct vectorized R function failed");
        }
        return;
    }
    if (!rducks_rc_scalar_execute(runtime, exec_meta, input, output, err_msg, sizeof(err_msg))) {
        duckdb_scalar_function_set_error(info, err_msg[0] ? err_msg : "Rducks direct scalar R function failed");
    }
}

