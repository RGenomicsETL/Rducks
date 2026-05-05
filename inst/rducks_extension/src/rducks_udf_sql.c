/* Included by ../rducks_extension.c. */

static bool rducks_register_r_scalar(rducks_runtime_entry_t *runtime, const char *name, SEXP eval_ref,
                                     const char *args_spec, const char *return_spec,
                                     const char *null_handling_spec, const char *exception_handling_spec,
                                     bool side_effects, const char *eval_mode_spec, char *err, size_t err_cap) {
    rducks_type_desc_t **arg_descs = NULL;
    rducks_type_desc_t *return_desc = NULL;
    size_t arity = 0;
    rducks_null_handling_t null_handling;
    rducks_exception_handling_t exception_handling;
    rducks_eval_mode_t eval_mode;
    rducks_r_scalar_meta_t *meta = NULL;
    duckdb_scalar_function fn = NULL;
    duckdb_logical_type return_logical_type = NULL;
    duckdb_state rc;
    if (!rducks_allow_calling_thread_r_execution(runtime, err, err_cap)) {
        return false;
    }
    if (!runtime || !runtime->connection || !name || !name[0]) {
        snprintf(err, err_cap, "invalid Rducks scalar registration request");
        return false;
    }
    if (!rducks_parse_eval_mode(eval_mode_spec, &eval_mode, err, err_cap)) {
        return false;
    }
    if ((eval_mode == RDUCKS_EVAL_R && !Rf_isFunction(eval_ref)) ||
        (eval_mode == RDUCKS_EVAL_RIPC && !rducks_ripc_bundle_valid(eval_ref)) ||
        ((eval_mode == RDUCKS_EVAL_RC || eval_mode == RDUCKS_EVAL_RCV) && !rducks_rc_bundle_valid(eval_ref))) {
        snprintf(err, err_cap, "invalid Rducks scalar registration evaluator for eval_mode");
        return false;
    }
    if (!rducks_parse_type_list(args_spec, &arg_descs, &arity, err, err_cap)) {
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
    if (!rducks_parse_exception_handling(exception_handling_spec, &exception_handling, err, err_cap)) {
        for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
        free(arg_descs);
        rducks_type_desc_destroy(return_desc);
        return false;
    }

    fn = duckdb_create_scalar_function();
    return_logical_type = rducks_create_logical_type_for_desc(return_desc);
    if (!fn || !return_logical_type) {
        snprintf(err, err_cap, "failed to allocate DuckDB scalar function for Rducks UDF");
        if (fn) {
            duckdb_destroy_scalar_function(&fn);
        }
        if (return_logical_type) {
            duckdb_destroy_logical_type(&return_logical_type);
        }
        for (size_t j = 0; j < arity; j++) rducks_type_desc_destroy(arg_descs[j]);
        free(arg_descs);
        rducks_type_desc_destroy(return_desc);
        return false;
    }

    duckdb_scalar_function_set_name(fn, name);
    for (size_t i = 0; i < arity; i++) {
        duckdb_logical_type arg_logical_type = rducks_create_logical_type_for_desc(arg_descs[i]);
        if (!arg_logical_type) {
            snprintf(err, err_cap, "failed to allocate DuckDB logical type for Rducks argument %zu", i + 1);
            duckdb_destroy_scalar_function(&fn);
            duckdb_destroy_logical_type(&return_logical_type);
            for (size_t j = 0; j < arity; j++) rducks_type_desc_destroy(arg_descs[j]);
            free(arg_descs);
            rducks_type_desc_destroy(return_desc);
            return false;
        }
        duckdb_scalar_function_add_parameter(fn, arg_logical_type);
        duckdb_destroy_logical_type(&arg_logical_type);
    }

    meta = (rducks_r_scalar_meta_t *)calloc(1, sizeof(rducks_r_scalar_meta_t));
    if (!meta) {
        snprintf(err, err_cap, "out of memory");
        duckdb_destroy_scalar_function(&fn);
        duckdb_destroy_logical_type(&return_logical_type);
        for (size_t j = 0; j < arity; j++) rducks_type_desc_destroy(arg_descs[j]);
        free(arg_descs);
        rducks_type_desc_destroy(return_desc);
        return false;
    }
    meta->fun = R_NilValue;
    meta->name = rducks_strdup(name);
    if (!meta->name) {
        snprintf(err, err_cap, "out of memory copying Rducks UDF name");
        free(meta);
        duckdb_destroy_scalar_function(&fn);
        duckdb_destroy_logical_type(&return_logical_type);
        for (size_t j = 0; j < arity; j++) rducks_type_desc_destroy(arg_descs[j]);
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
    meta->exception_handling = exception_handling;
    meta->eval_mode = eval_mode;
    meta->runtime = runtime;
    R_PreserveObject(eval_ref);
    meta->fun = eval_ref;

    duckdb_scalar_function_set_return_type(fn, return_logical_type);
    if (null_handling == RDUCKS_NULL_SPECIAL) {
        duckdb_scalar_function_set_special_handling(fn);
    }
    if (side_effects) {
        duckdb_scalar_function_set_volatile(fn);
    }
    duckdb_scalar_function_set_extra_info(fn, meta, rducks_r_scalar_meta_destroy);
    duckdb_scalar_function_set_bind(fn, rducks_r_scalar_bind);
    duckdb_scalar_function_set_init(fn, rducks_r_scalar_init);
    duckdb_scalar_function_set_function(fn, rducks_r_scalar_udf);
    rc = duckdb_register_scalar_function(runtime->connection, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&return_logical_type);
    if (rc != DuckDBSuccess) {
        snprintf(err, err_cap, "DuckDB failed to register Rducks scalar UDF %s", name);
        return false;
    }
    rducks_runtime_register_udf(runtime, meta);
    return true;
}

static void rducks_register_scalar_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    duckdb_string_t *names = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 0));
    uint64_t *fun_ptrs = (uint64_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 1));
    duckdb_string_t *args_specs = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 2));
    duckdb_string_t *return_specs = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 3));
    duckdb_string_t *null_handling_specs =
        (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 4));
    duckdb_string_t *exception_handling_specs =
        (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 5));
    bool *side_effects_values = (bool *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 6));
    duckdb_string_t *eval_mode_specs = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 7));
    bool *out = (bool *)duckdb_vector_get_data(output);
    if (!runtime) {
        duckdb_scalar_function_set_error(info, "Rducks runtime is not initialized for this connection");
        return;
    }

    for (idx_t i = 0; i < n; i++) {
        char *name = rducks_copy_duckdb_string(&names[i]);
        char *args_spec = rducks_copy_duckdb_string(&args_specs[i]);
        char *return_spec = rducks_copy_duckdb_string(&return_specs[i]);
        char *null_handling_spec = rducks_copy_duckdb_string(&null_handling_specs[i]);
        char *exception_handling_spec = rducks_copy_duckdb_string(&exception_handling_specs[i]);
        char *eval_mode_spec = rducks_copy_duckdb_string(&eval_mode_specs[i]);
        char err[256];
        SEXP eval_ref;
        err[0] = '\0';
        if (!name || !args_spec || !return_spec || !null_handling_spec || !exception_handling_spec || !eval_mode_spec) {
            free(name);
            free(args_spec);
            free(return_spec);
            free(null_handling_spec);
            free(exception_handling_spec);
            free(eval_mode_spec);
            duckdb_scalar_function_set_error(info, "out of memory");
            return;
        }
        eval_ref = (SEXP)(uintptr_t)fun_ptrs[i];
        out[i] = rducks_register_r_scalar(runtime, name, eval_ref, args_spec, return_spec, null_handling_spec,
                                          exception_handling_spec, side_effects_values[i], eval_mode_spec, err, sizeof(err));
        free(name);
        free(args_spec);
        free(return_spec);
        free(null_handling_spec);
        free(exception_handling_spec);
        free(eval_mode_spec);
        if (!out[i]) {
            duckdb_scalar_function_set_error(info, err[0] ? err : "Rducks scalar registration failed");
            return;
        }
    }
}

static void rducks_set_main_thread_token_scalar(duckdb_function_info info, duckdb_data_chunk input,
                                                duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    duckdb_string_t *tokens = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 0));
    bool *out = (bool *)duckdb_vector_get_data(output);
    if (!runtime) {
        duckdb_scalar_function_set_error(info, "Rducks runtime is not initialized for this connection");
        return;
    }

    for (idx_t i = 0; i < n; i++) {
        char *token = rducks_copy_duckdb_string(&tokens[i]);
        if (!token) {
            duckdb_scalar_function_set_error(info, "out of memory setting Rducks main thread token");
            return;
        }
        if (!rducks_set_main_thread_token(runtime, token)) {
            free(token);
            duckdb_scalar_function_set_error(info, "invalid Rducks main thread token");
            return;
        }
        free(token);
        out[i] = true;
    }
}

static void rducks_udf_stat_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    duckdb_string_t *names = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 0));
    duckdb_string_t *fields = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 1));
    if (!runtime) {
        duckdb_scalar_function_set_error(info, "Rducks runtime is not initialized for this connection");
        return;
    }

    for (idx_t i = 0; i < n; i++) {
        char *name = rducks_copy_duckdb_string(&names[i]);
        char *field = rducks_copy_duckdb_string(&fields[i]);
        char value[128];
        char err[256];
        err[0] = '\0';
        value[0] = '\0';
        if (!name || !field) {
            free(name);
            free(field);
            duckdb_scalar_function_set_error(info, "out of memory inspecting Rducks UDF stats");
            return;
        }
        if (!rducks_runtime_udf_stat(runtime, name, field, value, sizeof(value), err, sizeof(err))) {
            free(name);
            free(field);
            duckdb_scalar_function_set_error(info, err[0] ? err : "failed to inspect Rducks UDF stats");
            return;
        }
        duckdb_vector_assign_string_element(output, i, value);
        free(name);
        free(field);
    }
}

static void rducks_set_execution_backend_scalar(duckdb_function_info info, duckdb_data_chunk input,
                                                duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    duckdb_string_t *backends = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 0));
    bool *out = (bool *)duckdb_vector_get_data(output);
    if (!runtime) {
        duckdb_scalar_function_set_error(info, "Rducks runtime is not initialized for this connection");
        return;
    }

    for (idx_t i = 0; i < n; i++) {
        char *backend = rducks_copy_duckdb_string(&backends[i]);
        char err[256];
        err[0] = '\0';
        if (!backend) {
            duckdb_scalar_function_set_error(info, "out of memory setting Rducks execution backend");
            return;
        }
        out[i] = rducks_set_execution_backend(runtime, backend, err, sizeof(err)) ? true : false;
        free(backend);
        if (!out[i]) {
            duckdb_scalar_function_set_error(info, err[0] ? err : "failed to set Rducks execution backend");
            return;
        }
    }
}


