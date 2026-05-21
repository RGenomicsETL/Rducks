/* Included by ../rducks_extension.c. */

typedef struct rducks_r_aggregate_state {
    SEXP value;
    rducks_runtime_entry_t *runtime;
} rducks_r_aggregate_state_t;

typedef struct rducks_r_aggregate_meta {
    SEXP bundle;
    SEXP update_fun;
    SEXP combine_fun;
    SEXP finalize_fun;
    SEXP update_chunk_fun;
    SEXP combine_chunk_fun;
    SEXP finalize_chunk_fun;
    SEXP copy_fun;
    SEXP copy_chunk_fun;
    char *name;
    size_t arity;
    rducks_type_desc_t **args;
    rducks_type_desc_t *return_desc;
    rducks_null_handling_t null_handling;
    rducks_runtime_entry_t *runtime;
} rducks_r_aggregate_meta_t;

static void rducks_r_aggregate_release_preserved(rducks_runtime_entry_t *runtime, SEXP object) {
    if (!object || object == R_NilValue) return;
    if (rducks_is_main_thread(runtime)) {
        rducks_preserved_release_now(object);
    } else {
        rducks_preserved_release_enqueue(object);
    }
}

static SEXP rducks_r_aggregate_state_value(const rducks_r_aggregate_state_t *state) {
    if (!state || !state->value) return R_NilValue;
    return state->value;
}

static void rducks_r_aggregate_state_reset(rducks_r_aggregate_state_t *state) {
    SEXP old_value;
    if (!state) return;
    old_value = state->value;
    state->value = R_NilValue;
    rducks_r_aggregate_release_preserved(state->runtime, old_value);
}

static int rducks_r_aggregate_state_set(rducks_r_aggregate_state_t *state, SEXP value,
                                        char *err, size_t err_cap) {
    SEXP old_value;
    if (!state) {
        rducks_format_error_message(err, err_cap, "invalid Rducks aggregate state");
        return 0;
    }
    if (!value) value = R_NilValue;
    if (value == state->value) return 1;
    if (value != R_NilValue) R_PreserveObject(value);
    old_value = state->value;
    state->value = value;
    rducks_r_aggregate_release_preserved(state->runtime, old_value);
    return 1;
}

static void rducks_r_aggregate_set_error(duckdb_function_info info, const char *phase, const char *detail) {
    char msg[RDUCKS_ERROR_BUFFER_SIZE];
    if (detail && detail[0]) {
        rducks_format_error_message(msg, sizeof(msg), "Rducks aggregate %s failed: %s", phase, detail);
    } else {
        rducks_format_error_message(msg, sizeof(msg), "Rducks aggregate %s failed", phase);
    }
    duckdb_aggregate_function_set_error(info, msg);
}

typedef struct rducks_r_aggregate_eval_context {
    SEXP call;
    int ok;
    char err[RDUCKS_ERROR_BUFFER_SIZE];
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
        rducks_format_error_message(ctx->err, sizeof(ctx->err), "%s", CHAR(STRING_ELT(msg, 0)));
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
        rducks_format_error_message(err, err_cap, "%s", ctx.err[0] ? ctx.err : "R error");
    }
    return result;
}

static int rducks_r_aggregate_bundle_valid(SEXP bundle) {
    SEXP update_fun;
    SEXP finalize_fun;
    SEXP combine_fun;
    SEXP update_chunk_fun;
    SEXP combine_chunk_fun;
    SEXP finalize_chunk_fun;
    SEXP copy_fun;
    SEXP copy_chunk_fun;
    if (TYPEOF(bundle) != VECSXP) return 0;
    update_fun = rducks_named_list_get(bundle, "update");
    finalize_fun = rducks_named_list_get(bundle, "finalize");
    combine_fun = rducks_named_list_get(bundle, "combine");
    update_chunk_fun = rducks_named_list_get(bundle, "update_chunk");
    combine_chunk_fun = rducks_named_list_get(bundle, "combine_chunk");
    finalize_chunk_fun = rducks_named_list_get(bundle, "finalize_chunk");
    copy_fun = rducks_named_list_get(bundle, "copy");
    copy_chunk_fun = rducks_named_list_get(bundle, "copy_chunk");
    if (update_fun != R_NilValue && !Rf_isFunction(update_fun)) return 0;
    if (finalize_fun != R_NilValue && !Rf_isFunction(finalize_fun)) return 0;
    if (combine_fun != R_NilValue && !Rf_isFunction(combine_fun)) return 0;
    if (update_chunk_fun != R_NilValue && !Rf_isFunction(update_chunk_fun)) return 0;
    if (combine_chunk_fun != R_NilValue && !Rf_isFunction(combine_chunk_fun)) return 0;
    if (finalize_chunk_fun != R_NilValue && !Rf_isFunction(finalize_chunk_fun)) return 0;
    if (copy_fun != R_NilValue && !Rf_isFunction(copy_fun)) return 0;
    if (copy_chunk_fun != R_NilValue && !Rf_isFunction(copy_chunk_fun)) return 0;
    if (update_fun == R_NilValue && update_chunk_fun == R_NilValue) return 0;
    if (finalize_fun == R_NilValue && finalize_chunk_fun == R_NilValue) return 0;
    return 1;
}

static void rducks_r_aggregate_meta_destroy(void *ptr) {
    rducks_r_aggregate_meta_t *meta = (rducks_r_aggregate_meta_t *)ptr;
    if (!meta) return;
    if (meta->bundle && meta->bundle != R_NilValue) {
        rducks_r_aggregate_release_preserved(meta->runtime, meta->bundle);
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
    rducks_r_aggregate_meta_t *meta = (rducks_r_aggregate_meta_t *)duckdb_aggregate_function_get_extra_info(info);
    rducks_r_aggregate_state_t *agg_state = (rducks_r_aggregate_state_t *)state;
    if (!agg_state) return;
    agg_state->value = R_NilValue;
    agg_state->runtime = meta ? meta->runtime : NULL;
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
    args = PROTECT(Rf_allocList((int)meta->arity + 1));
    node = args;
    SETCAR(node, rducks_r_aggregate_state_value(state));
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

static int rducks_r_aggregate_row_selected(rducks_r_aggregate_meta_t *meta,
                                           rducks_rc_direct_vector_view_t *views,
                                           idx_t row) {
    return !(meta->null_handling == RDUCKS_NULL_DEFAULT && rducks_r_aggregate_row_has_null(meta, views, row));
}

static SEXP rducks_r_aggregate_state_list(rducks_r_aggregate_state_t **states,
                                          idx_t count,
                                          int *protect_count,
                                          char *err, size_t err_cap) {
    SEXP out;
    if (count > (idx_t)R_XLEN_T_MAX) {
        rducks_format_error_message(err, err_cap, "Rducks aggregate state batch is too large for R");
        return R_NilValue;
    }
    out = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)count));
    (*protect_count)++;
    for (idx_t i = 0; i < count; i++) {
        SET_VECTOR_ELT(out, (R_xlen_t)i, rducks_r_aggregate_state_value(states[i]));
    }
    return out;
}

static int rducks_r_aggregate_state_ptr_compare(const void *a, const void *b) {
    uintptr_t pa = (uintptr_t)*(rducks_r_aggregate_state_t * const *)a;
    uintptr_t pb = (uintptr_t)*(rducks_r_aggregate_state_t * const *)b;
    return (pa > pb) - (pa < pb);
}

static int rducks_r_aggregate_state_ptr_find(rducks_r_aggregate_state_t **states, idx_t count,
                                             rducks_r_aggregate_state_t *state, idx_t *index_out) {
    idx_t lo = 0;
    idx_t hi = count;
    uintptr_t needle = (uintptr_t)state;
    if (index_out) *index_out = 0;
    while (lo < hi) {
        idx_t mid = lo + (hi - lo) / 2U;
        uintptr_t cur = (uintptr_t)states[mid];
        if (cur == needle) {
            if (index_out) *index_out = mid;
            return 1;
        }
        if (cur < needle) {
            lo = mid + 1U;
        } else {
            hi = mid;
        }
    }
    return 0;
}

static int rducks_r_aggregate_update_vectorized(duckdb_function_info info,
                                                rducks_r_aggregate_meta_t *meta,
                                                duckdb_data_chunk input,
                                                duckdb_aggregate_state *states,
                                                rducks_rc_direct_vector_view_t *views,
                                                idx_t n,
                                                char *err, size_t err_cap) {
    rducks_r_aggregate_state_t **distinct_states = NULL;
    SEXP group_id = R_NilValue;
    SEXP full_columns = R_NilValue;
    SEXP state_list = R_NilValue;
    SEXP args = R_NilValue;
    SEXP call = R_NilValue;
    SEXP result = R_NilValue;
    int protect_count = 0;
    int ok = 1;
    idx_t state_count = 0;
    if (!Rf_isFunction(meta->update_chunk_fun)) return 0;
    if (n == 0) return 1;
    if (n > (idx_t)R_XLEN_T_MAX || n > (idx_t)INT_MAX || meta->arity > (size_t)INT_MAX) {
        rducks_format_error_message(err, err_cap, "Rducks aggregate vectorized update input is too large for R");
        return 0;
    }
    distinct_states = (rducks_r_aggregate_state_t **)rducks_calloc_array((size_t)n, sizeof(*distinct_states));
    if (!distinct_states) {
        rducks_format_error_message(err, err_cap, "out of memory preparing Rducks aggregate vectorized update");
        return 0;
    }
    group_id = PROTECT(Rf_allocVector(INTSXP, (R_xlen_t)n));
    protect_count++;
    for (idx_t row = 0; row < n; row++) {
        rducks_r_aggregate_state_t *state = (rducks_r_aggregate_state_t *)states[row];
        int selected = state && rducks_r_aggregate_row_selected(meta, views, row);
        INTEGER(group_id)[(R_xlen_t)row] = 0;
        if (selected) distinct_states[state_count++] = state;
    }
    if (state_count == 0) {
        free(distinct_states);
        UNPROTECT(protect_count);
        return 1;
    }
    qsort(distinct_states, (size_t)state_count, sizeof(*distinct_states), rducks_r_aggregate_state_ptr_compare);
    {
        idx_t unique_count = 1;
        for (idx_t i = 1; i < state_count; i++) {
            if (distinct_states[i] != distinct_states[unique_count - 1U]) {
                distinct_states[unique_count++] = distinct_states[i];
            }
        }
        state_count = unique_count;
    }
    if ((uint64_t)state_count > (uint64_t)INT_MAX) {
        free(distinct_states);
        UNPROTECT(protect_count);
        rducks_format_error_message(err, err_cap, "Rducks aggregate vectorized update has too many distinct states for R");
        return 0;
    }
    for (idx_t row = 0; row < n; row++) {
        rducks_r_aggregate_state_t *state = (rducks_r_aggregate_state_t *)states[row];
        idx_t found = 0;
        int selected = state && rducks_r_aggregate_row_selected(meta, views, row);
        if (!selected) continue;
        if (!rducks_r_aggregate_state_ptr_find(distinct_states, state_count, state, &found)) {
            free(distinct_states);
            UNPROTECT(protect_count);
            rducks_format_error_message(err, err_cap, "Rducks aggregate vectorized update failed to map a group state");
            return 0;
        }
        INTEGER(group_id)[(R_xlen_t)row] = (int)(found + 1U);
    }
    state_list = rducks_r_aggregate_state_list(distinct_states, state_count, &protect_count, err, err_cap);
    if (err[0] || state_list == R_NilValue) {
        free(distinct_states);
        UNPROTECT(protect_count);
        return 0;
    }

    full_columns = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)meta->arity));
    protect_count++;
    for (size_t col = 0; col < meta->arity; col++) {
        duckdb_vector vector = duckdb_data_chunk_get_vector(input, (idx_t)col);
        SEXP values = PROTECT(rducks_rc_direct_column_values(meta->args[col], vector, n, err, err_cap));
        if (err[0] || values == R_NilValue) {
            UNPROTECT(1);
            free(distinct_states);
            UNPROTECT(protect_count);
            return 0;
        }
        SET_VECTOR_ELT(full_columns, (R_xlen_t)col, values);
        UNPROTECT(1);
    }

    args = PROTECT(Rf_allocList((int)meta->arity + 2));
    protect_count++;
    SEXP node = args;
    SETCAR(node, state_list);
    node = CDR(node);
    SETCAR(node, group_id);
    node = CDR(node);
    for (size_t col = 0; col < meta->arity; col++) {
        SETCAR(node, VECTOR_ELT(full_columns, (R_xlen_t)col));
        node = CDR(node);
    }
    call = PROTECT(Rf_lcons(meta->update_chunk_fun, args));
    protect_count++;
    result = PROTECT(rducks_r_aggregate_eval_call(call, &ok, err, err_cap));
    protect_count++;
    if (!ok) {
        rducks_r_aggregate_set_error(info, "update_chunk", err);
        free(distinct_states);
        UNPROTECT(protect_count);
        return 0;
    }
    if (TYPEOF(result) != VECSXP || XLENGTH(result) != (R_xlen_t)state_count) {
        rducks_format_error_message(err, err_cap, "Rducks aggregate update_chunk must return a list with one replacement state per state group");
        free(distinct_states);
        UNPROTECT(protect_count);
        return 0;
    }
    for (idx_t i = 0; i < state_count; i++) {
        if (!rducks_r_aggregate_state_set(distinct_states[i], VECTOR_ELT(result, (R_xlen_t)i), err, err_cap)) {
            free(distinct_states);
            UNPROTECT(protect_count);
            return 0;
        }
    }
    free(distinct_states);
    UNPROTECT(protect_count);
    return 1;
}

static void rducks_r_aggregate_update(duckdb_function_info info, duckdb_data_chunk input,
                                      duckdb_aggregate_state *states) {
    rducks_r_aggregate_meta_t *meta = (rducks_r_aggregate_meta_t *)duckdb_aggregate_function_get_extra_info(info);
    rducks_rc_direct_vector_view_t *views = NULL;
    idx_t n = duckdb_data_chunk_get_size(input);
    char err[RDUCKS_ERROR_BUFFER_SIZE];
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
            rducks_rc_direct_view_init(&views[col], duckdb_data_chunk_get_vector(input, (idx_t)col));
        }
    }

    if (Rf_isFunction(meta->update_chunk_fun)) {
        if (!rducks_r_aggregate_update_vectorized(info, meta, input, states, views, n, err, sizeof(err))) {
            if (err[0]) rducks_r_aggregate_set_error(info, "update_chunk", err);
        }
        free(views);
        return;
    }

    if (!Rf_isFunction(meta->update_fun)) {
        duckdb_aggregate_function_set_error(info, "Rducks aggregate update function is missing");
        free(views);
        return;
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
        if (!rducks_r_aggregate_state_set(state, result, err, sizeof(err))) {
            rducks_r_aggregate_set_error(info, "update", err);
            UNPROTECT(2);
            free(views);
            return;
        }
        UNPROTECT(2);
    }
    free(views);
}

static int rducks_r_aggregate_copy_one(rducks_r_aggregate_meta_t *meta,
                                       rducks_r_aggregate_state_t *target,
                                       rducks_r_aggregate_state_t *source,
                                       char *err, size_t err_cap) {
    int ok = 1;
    SEXP src_value;
    SEXP result;
    if (!target || !source) {
        rducks_format_error_message(err, err_cap, "invalid Rducks aggregate state copy");
        return 0;
    }
    src_value = rducks_r_aggregate_state_value(source);
    if (src_value == R_NilValue) {
        rducks_r_aggregate_state_reset(target);
        return 1;
    }
    if (Rf_isFunction(meta->copy_fun)) {
        SEXP call = PROTECT(Rf_lang2(meta->copy_fun, src_value));
        result = PROTECT(rducks_r_aggregate_eval_call(call, &ok, err, err_cap));
        if (!ok) {
            if (err && err_cap > 0U && !err[0]) rducks_format_error_message(err, err_cap, "R copy function error");
            UNPROTECT(2);
            return 0;
        }
        if (!rducks_r_aggregate_state_set(target, result, err, err_cap)) {
            UNPROTECT(2);
            return 0;
        }
        UNPROTECT(2);
        return 1;
    }
    return rducks_r_aggregate_state_set(target, src_value, err, err_cap);
}

static int rducks_r_aggregate_copy_chunk(rducks_r_aggregate_meta_t *meta,
                                         rducks_r_aggregate_state_t **targets,
                                         rducks_r_aggregate_state_t **sources,
                                         idx_t count,
                                         char *err, size_t err_cap) {
    int ok = 1;
    int protect_count = 0;
    SEXP source_list;
    SEXP call;
    SEXP result;
    if (count == 0) return 1;
    if (!Rf_isFunction(meta->copy_chunk_fun)) {
        for (idx_t i = 0; i < count; i++) {
            if (!rducks_r_aggregate_copy_one(meta, targets[i], sources[i], err, err_cap)) return 0;
        }
        return 1;
    }
    source_list = rducks_r_aggregate_state_list(sources, count, &protect_count, err, err_cap);
    if (err[0] || source_list == R_NilValue) {
        UNPROTECT(protect_count);
        return 0;
    }
    call = PROTECT(Rf_lang2(meta->copy_chunk_fun, source_list));
    protect_count++;
    result = PROTECT(rducks_r_aggregate_eval_call(call, &ok, err, err_cap));
    protect_count++;
    if (!ok) {
        if (err && err_cap > 0U && !err[0]) rducks_format_error_message(err, err_cap, "R copy_chunk function error");
        UNPROTECT(protect_count);
        return 0;
    }
    if (TYPEOF(result) != VECSXP || XLENGTH(result) != (R_xlen_t)count) {
        rducks_format_error_message(err, err_cap, "Rducks aggregate copy_chunk must return a list with one copied state per source state");
        UNPROTECT(protect_count);
        return 0;
    }
    for (idx_t i = 0; i < count; i++) {
        if (!rducks_r_aggregate_state_set(targets[i], VECTOR_ELT(result, (R_xlen_t)i), err, err_cap)) {
            UNPROTECT(protect_count);
            return 0;
        }
    }
    UNPROTECT(protect_count);
    return 1;
}

static int rducks_r_aggregate_call_combine(rducks_r_aggregate_meta_t *meta,
                                           rducks_r_aggregate_state_t *target,
                                           rducks_r_aggregate_state_t *source,
                                           char *err, size_t err_cap) {
    int ok = 1;
    SEXP target_value;
    SEXP source_value;
    SEXP call;
    SEXP result;
    if (!Rf_isFunction(meta->combine_fun)) {
        rducks_format_error_message(err, err_cap,
                 "parallel aggregate combine is not supported for this Rducks aggregate; register a combine function and keep execution on the calling R thread");
        return 0;
    }
    target_value = rducks_r_aggregate_state_value(target);
    source_value = rducks_r_aggregate_state_value(source);
    call = PROTECT(Rf_lang3(meta->combine_fun, target_value, source_value));
    result = PROTECT(rducks_r_aggregate_eval_call(call, &ok, err, err_cap));
    if (!ok) {
        if (err && err_cap > 0U && !err[0]) rducks_format_error_message(err, err_cap, "R combine function error");
        UNPROTECT(2);
        return 0;
    }
    if (!rducks_r_aggregate_state_set(target, result, err, err_cap)) {
        UNPROTECT(2);
        return 0;
    }
    UNPROTECT(2);
    return 1;
}

static int rducks_r_aggregate_call_combine_chunk(rducks_r_aggregate_meta_t *meta,
                                                 rducks_r_aggregate_state_t **targets,
                                                 rducks_r_aggregate_state_t **sources,
                                                 idx_t count,
                                                 char *err, size_t err_cap) {
    int ok = 1;
    int protect_count = 0;
    SEXP target_list;
    SEXP source_list;
    SEXP call;
    SEXP result;
    if (count == 0) return 1;
    if (!Rf_isFunction(meta->combine_chunk_fun)) {
        rducks_format_error_message(err, err_cap, "Rducks aggregate vectorized combine function is missing");
        return 0;
    }
    target_list = rducks_r_aggregate_state_list(targets, count, &protect_count, err, err_cap);
    if (err[0] || target_list == R_NilValue) {
        UNPROTECT(protect_count);
        return 0;
    }
    source_list = rducks_r_aggregate_state_list(sources, count, &protect_count, err, err_cap);
    if (err[0] || source_list == R_NilValue) {
        UNPROTECT(protect_count);
        return 0;
    }
    call = PROTECT(Rf_lang3(meta->combine_chunk_fun, target_list, source_list));
    protect_count++;
    result = PROTECT(rducks_r_aggregate_eval_call(call, &ok, err, err_cap));
    protect_count++;
    if (!ok) {
        if (err && err_cap > 0U && !err[0]) rducks_format_error_message(err, err_cap, "R combine_chunk function error");
        UNPROTECT(protect_count);
        return 0;
    }
    if (TYPEOF(result) != VECSXP || XLENGTH(result) != (R_xlen_t)count) {
        rducks_format_error_message(err, err_cap, "Rducks aggregate combine_chunk must return a list with one state per combined state");
        UNPROTECT(protect_count);
        return 0;
    }
    for (idx_t i = 0; i < count; i++) {
        if (!rducks_r_aggregate_state_set(targets[i], VECTOR_ELT(result, (R_xlen_t)i), err, err_cap)) {
            UNPROTECT(protect_count);
            return 0;
        }
    }
    UNPROTECT(protect_count);
    return 1;
}

static void rducks_r_aggregate_combine(duckdb_function_info info, duckdb_aggregate_state *source,
                                       duckdb_aggregate_state *target, idx_t count) {
    rducks_r_aggregate_meta_t *meta = (rducks_r_aggregate_meta_t *)duckdb_aggregate_function_get_extra_info(info);
    rducks_r_aggregate_state_t **copy_targets = NULL;
    rducks_r_aggregate_state_t **copy_sources = NULL;
    rducks_r_aggregate_state_t **combine_targets = NULL;
    rducks_r_aggregate_state_t **combine_sources = NULL;
    idx_t copy_count = 0;
    idx_t pair_count = 0;
    char err[RDUCKS_ERROR_BUFFER_SIZE];
    err[0] = '\0';
    if (!meta || !source || !target) {
        duckdb_aggregate_function_set_error(info, "Rducks aggregate metadata is missing");
        return;
    }
    if (count == 0) return;
    if (!meta->runtime || !rducks_is_main_thread(meta->runtime)) {
        duckdb_aggregate_function_set_error(
            info,
            "Rducks aggregate combine reached a non-calling DuckDB execution thread; R-backed aggregate combine is single-threaded in this release"
        );
        return;
    }
    rducks_preserved_release_drain_on_main(meta->runtime);
    if ((uint64_t)count > (uint64_t)(SIZE_MAX / sizeof(*copy_targets))) {
        duckdb_aggregate_function_set_error(info, "Rducks aggregate combine batch is too large");
        return;
    }
    copy_targets = (rducks_r_aggregate_state_t **)rducks_calloc_array((size_t)count, sizeof(*copy_targets));
    copy_sources = (rducks_r_aggregate_state_t **)rducks_calloc_array((size_t)count, sizeof(*copy_sources));
    combine_targets = (rducks_r_aggregate_state_t **)rducks_calloc_array((size_t)count, sizeof(*combine_targets));
    combine_sources = (rducks_r_aggregate_state_t **)rducks_calloc_array((size_t)count, sizeof(*combine_sources));
    if (!copy_targets || !copy_sources || !combine_targets || !combine_sources) {
        free(copy_targets);
        free(copy_sources);
        free(combine_targets);
        free(combine_sources);
        duckdb_aggregate_function_set_error(info, "out of memory preparing Rducks aggregate combine");
        return;
    }
    for (idx_t i = 0; i < count; i++) {
        rducks_r_aggregate_state_t *src = (rducks_r_aggregate_state_t *)source[i];
        rducks_r_aggregate_state_t *dst = (rducks_r_aggregate_state_t *)target[i];
        if (!src || !dst || rducks_r_aggregate_state_value(src) == R_NilValue) continue;
        if (rducks_r_aggregate_state_value(dst) == R_NilValue) {
            copy_targets[copy_count] = dst;
            copy_sources[copy_count] = src;
            copy_count++;
            continue;
        }
        combine_targets[pair_count] = dst;
        combine_sources[pair_count] = src;
        pair_count++;
    }
    if (copy_count > 0 && !rducks_r_aggregate_copy_chunk(meta, copy_targets, copy_sources, copy_count, err, sizeof(err))) {
        free(copy_targets);
        free(copy_sources);
        free(combine_targets);
        free(combine_sources);
        rducks_r_aggregate_set_error(info, Rf_isFunction(meta->copy_chunk_fun) ? "copy_chunk" : "copy", err);
        return;
    }
    if (pair_count > 0) {
        if (Rf_isFunction(meta->combine_chunk_fun)) {
            if (!rducks_r_aggregate_call_combine_chunk(meta, combine_targets, combine_sources, pair_count, err, sizeof(err))) {
                free(copy_targets);
                free(copy_sources);
                free(combine_targets);
                free(combine_sources);
                rducks_r_aggregate_set_error(info, "combine_chunk", err);
                return;
            }
        } else {
            for (idx_t i = 0; i < pair_count; i++) {
                if (!rducks_r_aggregate_call_combine(meta, combine_targets[i], combine_sources[i], err, sizeof(err))) {
                    free(copy_targets);
                    free(copy_sources);
                    free(combine_targets);
                    free(combine_sources);
                    rducks_r_aggregate_set_error(info, "combine", err);
                    return;
                }
            }
        }
    }
    free(copy_targets);
    free(copy_sources);
    free(combine_targets);
    free(combine_sources);
}

static SEXP rducks_r_aggregate_finalize_chunk_value_at(SEXP values,
                                                       idx_t index,
                                                       idx_t count,
                                                       int *protect_count,
                                                       char *err, size_t err_cap) {
    if (values == R_NilValue) {
        if (count == 1) return R_NilValue;
        rducks_format_error_message(err, err_cap, "Rducks aggregate finalize_chunk returned NULL for more than one output state");
        return R_NilValue;
    }
    if (TYPEOF(values) == VECSXP && XLENGTH(values) == (R_xlen_t)count) {
        return VECTOR_ELT(values, (R_xlen_t)index);
    }
    if (XLENGTH(values) == (R_xlen_t)count) {
        int r_err = 0;
        SEXP idx;
        SEXP call;
        SEXP out;
        if (index >= (idx_t)INT_MAX) {
            rducks_format_error_message(err, err_cap, "Rducks aggregate finalize_chunk output index is too large for R indexing");
            return R_NilValue;
        }
        idx = PROTECT(Rf_ScalarInteger((int)index + 1));
        call = PROTECT(Rf_lang3(Rf_install("["), values, idx));
        out = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, &r_err));
        UNPROTECT(2); /* idx, call */
        if (r_err) {
            UNPROTECT(1); /* out */
            rducks_format_error_message(err, err_cap, "Rducks aggregate finalize_chunk failed while extracting output value");
            return R_NilValue;
        }
        (*protect_count)++;
        return out;
    }
    if (count == 1) return values;
    rducks_format_error_message(err, err_cap, "Rducks aggregate finalize_chunk must return a vector/list with one value per output state");
    return R_NilValue;
}

static int rducks_r_aggregate_finalize_vectorized(duckdb_function_info info,
                                                  rducks_r_aggregate_meta_t *meta,
                                                  duckdb_aggregate_state *source,
                                                  rducks_rc_direct_vector_view_t *output_view,
                                                  idx_t count,
                                                  idx_t offset,
                                                  char *err, size_t err_cap) {
    rducks_r_aggregate_state_t **states = NULL;
    int ok = 1;
    int protect_count = 0;
    SEXP state_list;
    SEXP call;
    SEXP values;
    if (count == 0) return 1;
    if (!Rf_isFunction(meta->finalize_chunk_fun)) {
        rducks_format_error_message(err, err_cap, "Rducks aggregate vectorized finalize function is missing");
        return 0;
    }
    if ((uint64_t)count > (uint64_t)(SIZE_MAX / sizeof(*states))) {
        rducks_format_error_message(err, err_cap, "Rducks aggregate finalize batch is too large");
        return 0;
    }
    states = (rducks_r_aggregate_state_t **)rducks_calloc_array((size_t)count, sizeof(*states));
    if (!states) {
        rducks_format_error_message(err, err_cap, "out of memory preparing Rducks aggregate finalize_chunk");
        return 0;
    }
    for (idx_t i = 0; i < count; i++) states[i] = (rducks_r_aggregate_state_t *)source[i];
    state_list = rducks_r_aggregate_state_list(states, count, &protect_count, err, err_cap);
    free(states);
    if (err[0] || state_list == R_NilValue) {
        UNPROTECT(protect_count);
        return 0;
    }
    call = PROTECT(Rf_lang2(meta->finalize_chunk_fun, state_list));
    protect_count++;
    values = PROTECT(rducks_r_aggregate_eval_call(call, &ok, err, err_cap));
    protect_count++;
    if (!ok) {
        if (err && err_cap > 0U && !err[0]) rducks_format_error_message(err, err_cap, "R finalize_chunk function error");
        UNPROTECT(protect_count);
        return 0;
    }
    for (idx_t i = 0; i < count; i++) {
        int value_protect_count = 0;
        SEXP value = rducks_r_aggregate_finalize_chunk_value_at(values, i, count,
                                                                &value_protect_count, err, err_cap);
        if (err[0]) {
            UNPROTECT(value_protect_count);
            UNPROTECT(protect_count);
            return 0;
        }
        if (!rducks_rc_write_direct_output(meta->return_desc, output_view, offset + i, value, err, err_cap)) {
            UNPROTECT(value_protect_count);
            UNPROTECT(protect_count);
            return 0;
        }
        UNPROTECT(value_protect_count);
    }
    UNPROTECT(protect_count);
    (void)info;
    return 1;
}

static void rducks_r_aggregate_finalize(duckdb_function_info info, duckdb_aggregate_state *source,
                                        duckdb_vector result, idx_t count, idx_t offset) {
    rducks_r_aggregate_meta_t *meta = (rducks_r_aggregate_meta_t *)duckdb_aggregate_function_get_extra_info(info);
    rducks_rc_direct_vector_view_t output_view;
    char err[RDUCKS_ERROR_BUFFER_SIZE];
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
    rducks_rc_direct_view_init(&output_view, result);

    if (Rf_isFunction(meta->finalize_chunk_fun)) {
        if (!rducks_r_aggregate_finalize_vectorized(info, meta, source, &output_view, count, offset, err, sizeof(err))) {
            rducks_r_aggregate_set_error(info, "finalize_chunk", err);
        }
        return;
    }

    if (!Rf_isFunction(meta->finalize_fun)) {
        duckdb_aggregate_function_set_error(info, "Rducks aggregate finalize function is missing");
        return;
    }

    for (idx_t i = 0; i < count; i++) {
        rducks_r_aggregate_state_t *state = (rducks_r_aggregate_state_t *)source[i];
        int ok = 1;
        SEXP state_value;
        SEXP call;
        SEXP value;
        state_value = rducks_r_aggregate_state_value(state);
        call = PROTECT(Rf_lang2(meta->finalize_fun, state_value));
        value = PROTECT(rducks_r_aggregate_eval_call(call, &ok, err, sizeof(err)));
        if (!ok) {
            rducks_r_aggregate_set_error(info, "finalize", err);
            UNPROTECT(2);
            return;
        }
        if (!rducks_rc_write_direct_output(meta->return_desc, &output_view, offset + i, value, err, sizeof(err))) {
            rducks_r_aggregate_set_error(info, "finalize", err);
            UNPROTECT(2);
            return;
        }
        UNPROTECT(2);
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
        rducks_format_error_message(err, err_cap, "invalid Rducks aggregate registration request");
        return false;
    }
    if (!rducks_r_aggregate_bundle_valid(bundle)) {
        rducks_format_error_message(err, err_cap, "invalid Rducks aggregate evaluator bundle");
        return false;
    }
    if (!rducks_parse_type_list(args_spec, &arg_descs, &arity, err, err_cap)) return false;
    if (arity < 1U) {
        rducks_format_error_message(err, err_cap, "Rducks aggregate UDFs require at least one input argument");
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
        rducks_format_error_message(err, err_cap, "failed to allocate DuckDB aggregate function for Rducks UDF");
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
            rducks_format_error_message(err, err_cap, "failed to allocate DuckDB logical type for Rducks aggregate argument %zu", i + 1);
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
        rducks_format_error_message(err, err_cap, "out of memory");
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
        rducks_format_error_message(err, err_cap, "out of memory copying Rducks aggregate name");
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
    meta->update_chunk_fun = rducks_named_list_get(bundle, "update_chunk");
    meta->combine_chunk_fun = rducks_named_list_get(bundle, "combine_chunk");
    meta->finalize_chunk_fun = rducks_named_list_get(bundle, "finalize_chunk");
    meta->copy_fun = rducks_named_list_get(bundle, "copy");
    meta->copy_chunk_fun = rducks_named_list_get(bundle, "copy_chunk");
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
        rducks_format_error_message(err, err_cap, "DuckDB failed to register Rducks aggregate UDF %s", name);
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
        char err[RDUCKS_ERROR_BUFFER_SIZE];
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
