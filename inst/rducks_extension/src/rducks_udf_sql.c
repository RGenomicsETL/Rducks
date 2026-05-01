/* Included by ../rducks_extension.c. */

static bool rducks_register_r_scalar(const char *name, SEXP fun, const char *args_spec, const char *return_spec,
                                     const char *null_handling_spec, const char *exception_handling_spec,
                                     bool side_effects, char *err, size_t err_cap) {
    rducks_type_desc_t **arg_descs = NULL;
    rducks_type_desc_t *return_desc = NULL;
    size_t arity = 0;
    rducks_null_handling_t null_handling;
    rducks_exception_handling_t exception_handling;
    rducks_r_scalar_meta_t *meta = NULL;
    duckdb_scalar_function fn = NULL;
    duckdb_logical_type return_logical_type = NULL;
    duckdb_state rc;
    if (!rducks_allow_direct_r_callback(err, err_cap)) {
        return false;
    }
    if (!g_connection || !name || !name[0] || !Rf_isFunction(fun)) {
        snprintf(err, err_cap, "invalid Rducks scalar registration request");
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
    meta->arity = arity;
    meta->args = arg_descs;
    arg_descs = NULL;
    meta->return_desc = return_desc;
    return_desc = NULL;
    meta->null_handling = null_handling;
    meta->exception_handling = exception_handling;
    meta->fun = fun;
    R_PreserveObject(fun);

    duckdb_scalar_function_set_return_type(fn, return_logical_type);
    if (null_handling == RDUCKS_NULL_SPECIAL) {
        duckdb_scalar_function_set_special_handling(fn);
    }
    if (side_effects) {
        duckdb_scalar_function_set_volatile(fn);
    }
    duckdb_scalar_function_set_extra_info(fn, meta, rducks_r_scalar_meta_destroy);
    duckdb_scalar_function_set_function(fn, rducks_r_scalar_udf);
    rc = duckdb_register_scalar_function(g_connection, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&return_logical_type);
    if (rc != DuckDBSuccess) {
        snprintf(err, err_cap, "DuckDB failed to register Rducks scalar UDF %s", name);
        return false;
    }
    return true;
}

static void rducks_register_scalar_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
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
    bool *out = (bool *)duckdb_vector_get_data(output);

    for (idx_t i = 0; i < n; i++) {
        char *name = rducks_copy_duckdb_string(&names[i]);
        char *args_spec = rducks_copy_duckdb_string(&args_specs[i]);
        char *return_spec = rducks_copy_duckdb_string(&return_specs[i]);
        char *null_handling_spec = rducks_copy_duckdb_string(&null_handling_specs[i]);
        char *exception_handling_spec = rducks_copy_duckdb_string(&exception_handling_specs[i]);
        char err[256];
        SEXP fun;
        err[0] = '\0';
        if (!name || !args_spec || !return_spec || !null_handling_spec || !exception_handling_spec) {
            free(name);
            free(args_spec);
            free(return_spec);
            free(null_handling_spec);
            free(exception_handling_spec);
            duckdb_scalar_function_set_error(info, "out of memory");
            return;
        }
        fun = (SEXP)(uintptr_t)fun_ptrs[i];
        out[i] = rducks_register_r_scalar(name, fun, args_spec, return_spec, null_handling_spec,
                                          exception_handling_spec, side_effects_values[i], err, sizeof(err));
        free(name);
        free(args_spec);
        free(return_spec);
        free(null_handling_spec);
        free(exception_handling_spec);
        if (!out[i]) {
            duckdb_scalar_function_set_error(info, err[0] ? err : "Rducks scalar registration failed");
            return;
        }
    }
}

static bool rducks_unregister_r_scalar(const char *name, const char *args_spec, const char *return_spec, char *err,
                                       size_t err_cap) {
    rducks_type_desc_t **arg_descs = NULL;
    rducks_type_desc_t *return_desc = NULL;
    size_t arity = 0;
    duckdb_scalar_function fn = NULL;
    duckdb_logical_type return_logical_type = NULL;
    rducks_inactive_scalar_meta_t *meta = NULL;
    duckdb_state rc;
    if (!rducks_allow_direct_r_callback(err, err_cap)) {
        return false;
    }
    if (!g_connection || !name || !name[0]) {
        snprintf(err, err_cap, "invalid Rducks scalar unregister request");
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
    fn = duckdb_create_scalar_function();
    return_logical_type = rducks_create_logical_type_for_desc(return_desc);
    if (!fn || !return_logical_type) {
        snprintf(err, err_cap, "failed to allocate DuckDB scalar function for Rducks unregister");
        if (fn) duckdb_destroy_scalar_function(&fn);
        if (return_logical_type) duckdb_destroy_logical_type(&return_logical_type);
        for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
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

    meta = (rducks_inactive_scalar_meta_t *)calloc(1, sizeof(rducks_inactive_scalar_meta_t));
    if (!meta) {
        snprintf(err, err_cap, "out of memory");
        duckdb_destroy_scalar_function(&fn);
        duckdb_destroy_logical_type(&return_logical_type);
        for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
        free(arg_descs);
        rducks_type_desc_destroy(return_desc);
        return false;
    }
    meta->name = rducks_strdup_len(name, strlen(name));
    if (!meta->name) {
        snprintf(err, err_cap, "out of memory");
        rducks_inactive_scalar_meta_destroy(meta);
        duckdb_destroy_scalar_function(&fn);
        duckdb_destroy_logical_type(&return_logical_type);
        for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
        free(arg_descs);
        rducks_type_desc_destroy(return_desc);
        return false;
    }

    duckdb_scalar_function_set_return_type(fn, return_logical_type);
    duckdb_scalar_function_set_special_handling(fn);
    duckdb_scalar_function_set_extra_info(fn, meta, rducks_inactive_scalar_meta_destroy);
    meta = NULL;
    duckdb_scalar_function_set_function(fn, rducks_inactive_scalar_udf);
    rc = duckdb_register_scalar_function(g_connection, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&return_logical_type);
    for (size_t i = 0; i < arity; i++) rducks_type_desc_destroy(arg_descs[i]);
    free(arg_descs);
    rducks_type_desc_destroy(return_desc);
    if (rc != DuckDBSuccess) {
        snprintf(err, err_cap, "DuckDB failed to unregister Rducks scalar UDF %s", name);
        return false;
    }
    return true;
}

static void rducks_unregister_scalar_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    idx_t n = duckdb_data_chunk_get_size(input);
    duckdb_string_t *names = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 0));
    duckdb_string_t *args_specs = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 1));
    duckdb_string_t *return_specs = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 2));
    bool *out = (bool *)duckdb_vector_get_data(output);

    for (idx_t i = 0; i < n; i++) {
        char *name = rducks_copy_duckdb_string(&names[i]);
        char *args_spec = rducks_copy_duckdb_string(&args_specs[i]);
        char *return_spec = rducks_copy_duckdb_string(&return_specs[i]);
        char err[256];
        err[0] = '\0';
        if (!name || !args_spec || !return_spec) {
            free(name);
            free(args_spec);
            free(return_spec);
            duckdb_scalar_function_set_error(info, "out of memory");
            return;
        }
        out[i] = rducks_unregister_r_scalar(name, args_spec, return_spec, err, sizeof(err));
        free(name);
        free(args_spec);
        free(return_spec);
        if (!out[i]) {
            duckdb_scalar_function_set_error(info, err[0] ? err : "Rducks scalar unregister failed");
            return;
        }
    }
}

static void rducks_set_main_thread_token_scalar(duckdb_function_info info, duckdb_data_chunk input,
                                                duckdb_vector output) {
    idx_t n = duckdb_data_chunk_get_size(input);
    duckdb_string_t *tokens = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 0));
    bool *out = (bool *)duckdb_vector_get_data(output);

    for (idx_t i = 0; i < n; i++) {
        char *token = rducks_copy_duckdb_string(&tokens[i]);
        if (!token) {
            duckdb_scalar_function_set_error(info, "out of memory setting Rducks main thread token");
            return;
        }
        rducks_set_main_thread_token(token);
        rducks_initialize_fallback_arrow_options();
        free(token);
        out[i] = true;
    }
}


