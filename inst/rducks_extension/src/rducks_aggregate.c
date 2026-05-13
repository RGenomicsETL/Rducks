/* Included by ../rducks_extension.c. */

typedef struct rducks_r_aggregate_state {
    uint8_t *data;
    size_t size;
    int is_null;
} rducks_r_aggregate_state_t;

typedef struct rducks_r_aggregate_meta {
    SEXP bundle;
    SEXP update_fun;
    SEXP combine_fun;
    SEXP finalize_fun;
    char *name;
    size_t arity;
    rducks_type_desc_t **args;
    rducks_type_desc_t *return_desc;
    rducks_null_handling_t null_handling;
    rducks_runtime_entry_t *runtime;
} rducks_r_aggregate_meta_t;

static void rducks_r_aggregate_state_reset(rducks_r_aggregate_state_t *state) {
    if (!state) return;
    free(state->data);
    state->data = NULL;
    state->size = 0;
    state->is_null = 1;
}

static int rducks_r_aggregate_state_copy(rducks_r_aggregate_state_t *dst,
                                         const rducks_r_aggregate_state_t *src,
                                         char *err, size_t err_cap) {
    uint8_t *copy = NULL;
    if (!dst || !src) {
        snprintf(err, err_cap, "invalid Rducks aggregate state copy");
        return 0;
    }
    if (src->is_null) {
        rducks_r_aggregate_state_reset(dst);
        return 1;
    }
    if (src->size > 0U) {
        if (!src->data) {
            snprintf(err, err_cap, "invalid non-empty Rducks aggregate state");
            return 0;
        }
        copy = (uint8_t *)malloc(src->size);
        if (!copy) {
            snprintf(err, err_cap, "out of memory copying Rducks aggregate state");
            return 0;
        }
        memcpy(copy, src->data, src->size);
    }
    free(dst->data);
    dst->data = copy;
    dst->size = src->size;
    dst->is_null = 0;
    return 1;
}

static SEXP rducks_r_aggregate_state_to_raw(const rducks_r_aggregate_state_t *state) {
    SEXP out;
    if (!state || state->is_null) return R_NilValue;
    if (state->size > (size_t)R_XLEN_T_MAX) {
        Rf_error("Rducks aggregate state is too large to materialize in R");
    }
    out = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)state->size));
    if (state->size > 0U) memcpy(RAW(out), state->data, state->size);
    UNPROTECT(1);
    return out;
}

static int rducks_r_aggregate_state_from_raw(rducks_r_aggregate_state_t *state, SEXP value,
                                             char *err, size_t err_cap) {
    uint8_t *copy = NULL;
    R_xlen_t n;
    if (!state) {
        snprintf(err, err_cap, "invalid Rducks aggregate state");
        return 0;
    }
    if (value == R_NilValue) {
        rducks_r_aggregate_state_reset(state);
        return 1;
    }
    if (TYPEOF(value) != RAWSXP) {
        snprintf(err, err_cap, "Rducks aggregate update/combine must return a raw vector state or NULL");
        return 0;
    }
    n = XLENGTH(value);
    if (n < 0 || (uint64_t)n > (uint64_t)SIZE_MAX) {
        snprintf(err, err_cap, "Rducks aggregate state is too large");
        return 0;
    }
    if (n > 0) {
        copy = (uint8_t *)malloc((size_t)n);
        if (!copy) {
            snprintf(err, err_cap, "out of memory copying Rducks aggregate state");
            return 0;
        }
        memcpy(copy, RAW(value), (size_t)n);
    }
    free(state->data);
    state->data = copy;
    state->size = (size_t)n;
    state->is_null = 0;
    return 1;
}

static void rducks_r_aggregate_set_error(duckdb_function_info info, const char *phase, const char *detail) {
    char msg[512];
    if (detail && detail[0]) {
        snprintf(msg, sizeof(msg), "Rducks aggregate %s failed: %s", phase, detail);
    } else {
        snprintf(msg, sizeof(msg), "Rducks aggregate %s failed", phase);
    }
    duckdb_aggregate_function_set_error(info, msg);
}

typedef struct rducks_r_aggregate_eval_context {
    SEXP call;
    int ok;
    char err[256];
} rducks_r_aggregate_eval_context_t;

static SEXP rducks_r_aggregate_eval_body(void *data) {
    rducks_r_aggregate_eval_context_t *ctx = (rducks_r_aggregate_eval_context_t *)data;
    ctx->ok = 1;
    return Rf_eval(ctx->call, R_GlobalEnv);
}

static SEXP rducks_r_aggregate_eval_error(SEXP condition, void *data) {
    rducks_r_aggregate_eval_context_t *ctx = (rducks_r_aggregate_eval_context_t *)data;
    int r_err = 0;
    ctx->ok = 0;
    ctx->err[0] = '\0';
    SEXP fun = PROTECT(Rf_findFun(Rf_install("conditionMessage"), R_BaseEnv));
    SEXP call = PROTECT(Rf_lang2(fun, condition));
    SEXP msg = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, &r_err));
    if (!r_err && TYPEOF(msg) == STRSXP && XLENGTH(msg) > 0 && STRING_ELT(msg, 0) != NA_STRING) {
        snprintf(ctx->err, sizeof(ctx->err), "%s", CHAR(STRING_ELT(msg, 0)));
    }
    UNPROTECT(3);
    return R_NilValue;
}

static SEXP rducks_r_aggregate_eval_call(SEXP call, int *ok, char *err, size_t err_cap) {
    rducks_r_aggregate_eval_context_t ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.call = call;
    ctx.ok = 1;
    SEXP result = R_tryCatchError(rducks_r_aggregate_eval_body, &ctx,
                                  rducks_r_aggregate_eval_error, &ctx);
    if (ok) *ok = ctx.ok;
    if (!ctx.ok && err && err_cap > 0U) {
        snprintf(err, err_cap, "%s", ctx.err[0] ? ctx.err : "R error");
    }
    return result;
}

static int rducks_r_aggregate_bundle_valid(SEXP bundle) {
    SEXP update_fun;
    SEXP finalize_fun;
    SEXP combine_fun;
    if (TYPEOF(bundle) != VECSXP) return 0;
    update_fun = rducks_named_list_get(bundle, "update");
    finalize_fun = rducks_named_list_get(bundle, "finalize");
    combine_fun = rducks_named_list_get(bundle, "combine");
    if (!Rf_isFunction(update_fun) || !Rf_isFunction(finalize_fun)) return 0;
    if (combine_fun != R_NilValue && !Rf_isFunction(combine_fun)) return 0;
    return 1;
}

static void rducks_r_aggregate_meta_destroy(void *ptr) {
    rducks_r_aggregate_meta_t *meta = (rducks_r_aggregate_meta_t *)ptr;
    if (!meta) return;
    if (meta->bundle && meta->bundle != R_NilValue) {
        if (rducks_is_main_thread(meta->runtime)) {
            rducks_preserved_release_now(meta->bundle);
        } else {
            rducks_preserved_release_enqueue(meta->bundle);
        }
        meta->bundle = R_NilValue;
    }
    free(meta->name);
    if (meta->args) {
        for (size_t i = 0; i < meta->arity; i++) rducks_type_desc_destroy(meta->args[i]);
    }
    free(meta->args);
    rducks_type_desc_destroy(meta->return_desc);
    free(meta);
}

static idx_t rducks_r_aggregate_state_size(duckdb_function_info info) {
    (void)info;
    return (idx_t)sizeof(rducks_r_aggregate_state_t);
}

static void rducks_r_aggregate_init(duckdb_function_info info, duckdb_aggregate_state state) {
    (void)info;
    rducks_r_aggregate_state_t *agg_state = (rducks_r_aggregate_state_t *)state;
    if (!agg_state) return;
    agg_state->data = NULL;
    agg_state->size = 0;
    agg_state->is_null = 1;
}

static void rducks_r_aggregate_destroy(duckdb_aggregate_state *states, idx_t count) {
    if (!states) return;
    for (idx_t i = 0; i < count; i++) {
        rducks_r_aggregate_state_reset((rducks_r_aggregate_state_t *)states[i]);
    }
}

static int rducks_r_aggregate_row_has_null(rducks_r_aggregate_meta_t *meta,
                                           rducks_rc_direct_vector_view_t *views,
                                           idx_t row) {
    for (size_t col = 0; col < meta->arity; col++) {
        if (!rducks_rc_direct_view_valid_at(&views[col], row)) return 1;
    }
    return 0;
}

static SEXP rducks_r_aggregate_update_call(rducks_r_aggregate_meta_t *meta,
                                           rducks_r_aggregate_state_t *state,
                                           rducks_rc_direct_vector_view_t *views,
                                           idx_t row) {
    SEXP args;
    SEXP call;
    SEXP node;
    SEXP state_raw;
    args = PROTECT(Rf_allocList((int)meta->arity + 1));
    node = args;
    state_raw = rducks_r_aggregate_state_to_raw(state);
    SETCAR(node, state_raw);
    node = CDR(node);
    for (size_t col = 0; col < meta->arity; col++) {
        SEXP arg = rducks_rc_direct_arg(meta->args[col], &views[col], row);
        SETCAR(node, arg);
        node = CDR(node);
    }
    call = PROTECT(Rf_lcons(meta->update_fun, args));
    UNPROTECT(2);
    return call;
}

static void rducks_r_aggregate_update(duckdb_function_info info, duckdb_data_chunk input,
                                      duckdb_aggregate_state *states) {
    rducks_r_aggregate_meta_t *meta = (rducks_r_aggregate_meta_t *)duckdb_aggregate_function_get_extra_info(info);
    rducks_rc_direct_vector_view_t *views = NULL;
    idx_t n = duckdb_data_chunk_get_size(input);
    char err[256];
    err[0] = '\0';

    if (!meta || !meta->runtime || !states) {
        duckdb_aggregate_function_set_error(info, "Rducks aggregate metadata is missing");
        return;
    }
    if (!rducks_is_main_thread(meta->runtime)) {
        duckdb_aggregate_function_set_error(
            info,
            "Rducks aggregate UDF reached a non-calling DuckDB execution thread; use rducks_enable(con, threads = 'single') before executing R-backed aggregates"
        );
        return;
    }
    rducks_preserved_release_drain_on_main(meta->runtime);

    if (meta->arity > 0U) {
        views = (rducks_rc_direct_vector_view_t *)rducks_calloc_array(meta->arity, sizeof(*views));
        if (!views) {
            duckdb_aggregate_function_set_error(info, "out of memory preparing Rducks aggregate inputs");
            return;
        }
        for (size_t col = 0; col < meta->arity; col++) {
            rducks_rc_direct_input_view_init(&views[col], duckdb_data_chunk_get_vector(input, (idx_t)col));
        }
    }

    for (idx_t row = 0; row < n; row++) {
        rducks_r_aggregate_state_t *state = (rducks_r_aggregate_state_t *)states[row];
        int ok = 1;
        SEXP call;
        SEXP result;
        if (!state) continue;
        if (meta->null_handling == RDUCKS_NULL_DEFAULT && rducks_r_aggregate_row_has_null(meta, views, row)) {
            continue;
        }
        call = PROTECT(rducks_r_aggregate_update_call(meta, state, views, row));
        result = PROTECT(rducks_r_aggregate_eval_call(call, &ok, err, sizeof(err)));
        if (!ok) {
            rducks_r_aggregate_set_error(info, "update", err);
            UNPROTECT(2);
            free(views);
            return;
        }
        if (!rducks_r_aggregate_state_from_raw(state, result, err, sizeof(err))) {
            rducks_r_aggregate_set_error(info, "update", err);
            UNPROTECT(2);
            free(views);
            return;
        }
        UNPROTECT(2);
    }
    free(views);
}

static int rducks_r_aggregate_call_combine(rducks_r_aggregate_meta_t *meta,
                                           rducks_r_aggregate_state_t *target,
                                           rducks_r_aggregate_state_t *source,
                                           char *err, size_t err_cap) {
    int ok = 1;
    SEXP target_raw;
    SEXP source_raw;
    SEXP call;
    SEXP result;
    if (!Rf_isFunction(meta->combine_fun)) {
        snprintf(err, err_cap,
                 "parallel aggregate combine is not supported for this Rducks aggregate; register a combine function and keep execution on the calling R thread");
        return 0;
    }
    target_raw = PROTECT(rducks_r_aggregate_state_to_raw(target));
    source_raw = PROTECT(rducks_r_aggregate_state_to_raw(source));
    call = PROTECT(Rf_lang3(meta->combine_fun, target_raw, source_raw));
    result = PROTECT(rducks_r_aggregate_eval_call(call, &ok, err, err_cap));
    if (!ok) {
        if (err && err_cap > 0U && !err[0]) snprintf(err, err_cap, "R combine function error");
        UNPROTECT(4);
        return 0;
    }
    if (!rducks_r_aggregate_state_from_raw(target, result, err, err_cap)) {
        UNPROTECT(4);
        return 0;
    }
    UNPROTECT(4);
    return 1;
}

static void rducks_r_aggregate_combine(duckdb_function_info info, duckdb_aggregate_state *source,
                                       duckdb_aggregate_state *target, idx_t count) {
    rducks_r_aggregate_meta_t *meta = (rducks_r_aggregate_meta_t *)duckdb_aggregate_function_get_extra_info(info);
    char err[256];
    err[0] = '\0';
    if (!meta || !source || !target) {
        duckdb_aggregate_function_set_error(info, "Rducks aggregate metadata is missing");
        return;
    }
    for (idx_t i = 0; i < count; i++) {
        rducks_r_aggregate_state_t *src = (rducks_r_aggregate_state_t *)source[i];
        rducks_r_aggregate_state_t *dst = (rducks_r_aggregate_state_t *)target[i];
        if (!src || !dst || src->is_null) continue;
        if (dst->is_null) {
            if (!rducks_r_aggregate_state_copy(dst, src, err, sizeof(err))) {
                rducks_r_aggregate_set_error(info, "combine", err);
                return;
            }
            continue;
        }
        if (!meta->runtime || !rducks_is_main_thread(meta->runtime)) {
            duckdb_aggregate_function_set_error(
                info,
                "Rducks aggregate combine reached a non-calling DuckDB execution thread; R-backed aggregate combine is single-threaded in this release"
            );
            return;
        }
        rducks_preserved_release_drain_on_main(meta->runtime);
        if (!rducks_r_aggregate_call_combine(meta, dst, src, err, sizeof(err))) {
            rducks_r_aggregate_set_error(info, "combine", err);
            return;
        }
    }
}

static void rducks_r_aggregate_finalize(duckdb_function_info info, duckdb_aggregate_state *source,
                                        duckdb_vector result, idx_t count, idx_t offset) {
    rducks_r_aggregate_meta_t *meta = (rducks_r_aggregate_meta_t *)duckdb_aggregate_function_get_extra_info(info);
    rducks_rc_direct_vector_view_t output_view;
    char err[256];
    err[0] = '\0';
    if (!meta || !meta->runtime || !source) {
        duckdb_aggregate_function_set_error(info, "Rducks aggregate metadata is missing");
        return;
    }
    if (!rducks_is_main_thread(meta->runtime)) {
        duckdb_aggregate_function_set_error(
            info,
            "Rducks aggregate finalize reached a non-calling DuckDB execution thread; use rducks_enable(con, threads = 'single') before executing R-backed aggregates"
        );
        return;
    }
    rducks_preserved_release_drain_on_main(meta->runtime);
    rducks_rc_direct_output_view_init(&output_view, result);
    for (idx_t i = 0; i < count; i++) {
        rducks_r_aggregate_state_t *state = (rducks_r_aggregate_state_t *)source[i];
        int ok = 1;
        SEXP state_raw;
        SEXP call;
        SEXP value;
        state_raw = PROTECT(rducks_r_aggregate_state_to_raw(state));
        call = PROTECT(Rf_lang2(meta->finalize_fun, state_raw));
        value = PROTECT(rducks_r_aggregate_eval_call(call, &ok, err, sizeof(err)));
        if (!ok) {
            rducks_r_aggregate_set_error(info, "finalize", err);
            UNPROTECT(3);
            return;
        }
        if (!rducks_rc_write_direct_output(meta->return_desc, &output_view, offset + i, value, err, sizeof(err))) {
            rducks_r_aggregate_set_error(info, "finalize", err);
            UNPROTECT(3);
            return;
        }
        UNPROTECT(3);
    }
}

static bool rducks_register_r_aggregate(rducks_runtime_entry_t *runtime, const char *name, SEXP bundle,
                                        const char *args_spec, const char *return_spec,
                                        const char *null_handling_spec, char *err, size_t err_cap) {
    rducks_type_desc_t **arg_descs = NULL;
    rducks_type_desc_t *return_desc = NULL;
    size_t arity = 0;
    rducks_null_handling_t null_handling;
    rducks_r_aggregate_meta_t *meta = NULL;
    duckdb_aggregate_function fn = NULL;
    duckdb_logical_type return_logical_type = NULL;
    duckdb_state rc;

    if (!rducks_allow_calling_thread_r_execution(runtime, err, err_cap)) return false;
    rducks_preserved_release_drain_on_main(runtime);
    if (!runtime || !runtime->connection || !name || !name[0]) {
        snprintf(err, err_cap, "invalid Rducks aggregate registration request");
        return false;
    }
    if (!rducks_r_aggregate_bundle_valid(bundle)) {
        snprintf(err, err_cap, "invalid Rducks aggregate evaluator bundle");
        return false;
    }
    if (!rducks_parse_type_list(args_spec, &arg_descs, &arity, err, err_cap)) return false;
    if (arity < 1U) {
        snprintf(err, err_cap, "Rducks aggregate UDFs require at least one input argument");
        free(arg_descs);
        return false;
    }
    if (!rducks_parse_type_desc_text(return_spec, &return_desc, err, err_cap)) {
        for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
        free(arg_descs);
        return false;
    }
    if (!rducks_parse_null_handling(null_handling_spec, &null_handling, err, err_cap)) {
        for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
        free(arg_descs);
        rducks_type_desc_destroy(return_desc);
        return false;
    }

    fn = duckdb_create_aggregate_function();
    return_logical_type = rducks_create_logical_type_for_desc(return_desc);
    if (!fn || !return_logical_type) {
        snprintf(err, err_cap, "failed to allocate DuckDB aggregate function for Rducks UDF");
        if (fn) duckdb_destroy_aggregate_function(&fn);
        if (return_logical_type) duckdb_destroy_logical_type(&return_logical_type);
        for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
        free(arg_descs);
        rducks_type_desc_destroy(return_desc);
        return false;
    }

    duckdb_aggregate_function_set_name(fn, name);
    for (size_t i = 0; i < arity; i++) {
        duckdb_logical_type arg_logical_type = rducks_create_logical_type_for_desc(arg_descs[i]);
        if (!arg_logical_type) {
            snprintf(err, err_cap, "failed to allocate DuckDB logical type for Rducks aggregate argument %zu", i + 1);
            duckdb_destroy_aggregate_function(&fn);
            duckdb_destroy_logical_type(&return_logical_type);
            for (size_t j = 0; j < arity; j++) rducks_type_desc_destroy(arg_descs[j]);
            free(arg_descs);
            rducks_type_desc_destroy(return_desc);
            return false;
        }
        duckdb_aggregate_function_add_parameter(fn, arg_logical_type);
        duckdb_destroy_logical_type(&arg_logical_type);
    }

    meta = (rducks_r_aggregate_meta_t *)rducks_calloc_array(1, sizeof(*meta));
    if (!meta) {
        snprintf(err, err_cap, "out of memory");
        duckdb_destroy_aggregate_function(&fn);
        duckdb_destroy_logical_type(&return_logical_type);
        for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
        free(arg_descs);
        rducks_type_desc_destroy(return_desc);
        return false;
    }
    meta->bundle = R_NilValue;
    meta->name = rducks_strdup(name);
    if (!meta->name) {
        snprintf(err, err_cap, "out of memory copying Rducks aggregate name");
        free(meta);
        duckdb_destroy_aggregate_function(&fn);
        duckdb_destroy_logical_type(&return_logical_type);
        for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
        free(arg_descs);
        rducks_type_desc_destroy(return_desc);
        return false;
    }
    meta->arity = arity;
    meta->args = arg_descs;
    arg_descs = NULL;
    meta->return_desc = return_desc;
    return_desc = NULL;
    meta->null_handling = null_handling;
    meta->runtime = runtime;
    meta->update_fun = rducks_named_list_get(bundle, "update");
    meta->combine_fun = rducks_named_list_get(bundle, "combine");
    meta->finalize_fun = rducks_named_list_get(bundle, "finalize");
    R_PreserveObject(bundle);
    meta->bundle = bundle;

    duckdb_aggregate_function_set_return_type(fn, return_logical_type);
    duckdb_aggregate_function_set_functions(fn, rducks_r_aggregate_state_size,
                                            rducks_r_aggregate_init,
                                            rducks_r_aggregate_update,
                                            rducks_r_aggregate_combine,
                                            rducks_r_aggregate_finalize);
    duckdb_aggregate_function_set_destructor(fn, rducks_r_aggregate_destroy);
    if (null_handling == RDUCKS_NULL_SPECIAL) {
        duckdb_aggregate_function_set_special_handling(fn);
    }
    duckdb_aggregate_function_set_extra_info(fn, meta, rducks_r_aggregate_meta_destroy);
    rc = duckdb_register_aggregate_function(runtime->connection, fn);
    duckdb_destroy_aggregate_function(&fn);
    duckdb_destroy_logical_type(&return_logical_type);
    if (rc != DuckDBSuccess) {
        snprintf(err, err_cap, "DuckDB failed to register Rducks aggregate UDF %s", name);
        return false;
    }
    return true;
}

static void rducks_register_aggregate_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    duckdb_string_t *names = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 0));
    duckdb_string_t *evaluator_ids = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 1));
    duckdb_string_t *evaluator_tokens = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 2));
    duckdb_string_t *args_specs = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 3));
    duckdb_string_t *return_specs = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 4));
    duckdb_string_t *null_handling_specs =
        (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 5));
    bool *out = (bool *)duckdb_vector_get_data(output);
    if (!runtime) {
        duckdb_scalar_function_set_error(info, "Rducks runtime is not initialized for this connection");
        return;
    }
    for (idx_t i = 0; i < n; i++) {
        char *name = rducks_copy_duckdb_string(&names[i]);
        char *evaluator_id = rducks_copy_duckdb_string(&evaluator_ids[i]);
        char *evaluator_token = rducks_copy_duckdb_string(&evaluator_tokens[i]);
        char *args_spec = rducks_copy_duckdb_string(&args_specs[i]);
        char *return_spec = rducks_copy_duckdb_string(&return_specs[i]);
        char *null_handling_spec = rducks_copy_duckdb_string(&null_handling_specs[i]);
        char err[256];
        SEXP bundle = R_NilValue;
        err[0] = '\0';
        if (!name || !evaluator_id || !evaluator_token || !args_spec || !return_spec || !null_handling_spec) {
            free(name);
            free(evaluator_id);
            free(evaluator_token);
            free(args_spec);
            free(return_spec);
            free(null_handling_spec);
            duckdb_scalar_function_set_error(info, "out of memory");
            return;
        }
        if (!rducks_allow_calling_thread_r_execution(runtime, err, sizeof(err)) ||
            !rducks_lookup_evaluator_ref(evaluator_id, evaluator_token, &bundle, err, sizeof(err))) {
            free(name);
            free(evaluator_id);
            free(evaluator_token);
            free(args_spec);
            free(return_spec);
            free(null_handling_spec);
            duckdb_scalar_function_set_error(info, err[0] ? err : "invalid Rducks evaluator handle");
            return;
        }
        out[i] = rducks_register_r_aggregate(runtime, name, bundle, args_spec, return_spec,
                                             null_handling_spec, err, sizeof(err));
        free(name);
        free(evaluator_id);
        free(evaluator_token);
        free(args_spec);
        free(return_spec);
        free(null_handling_spec);
        if (!out[i]) {
            duckdb_scalar_function_set_error(info, err[0] ? err : "Rducks aggregate registration failed");
            return;
        }
    }
}
