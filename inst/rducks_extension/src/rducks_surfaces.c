/* Included by ../rducks_extension.c. */

static void rducks_version_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    (void)info;
    idx_t n = duckdb_data_chunk_get_size(input);
    for (idx_t i = 0; i < n; i++) {
        duckdb_vector_assign_string_element(output, i, "Rducks extension loaded");
    }
}

static bool rducks_register_scalar_surface(duckdb_connection con, rducks_runtime_entry_t *runtime) {
    duckdb_scalar_function fn = duckdb_create_scalar_function();
    duckdb_logical_type varchar_type = duckdb_create_logical_type(DUCKDB_TYPE_VARCHAR);
    duckdb_logical_type ubigint_type = duckdb_create_logical_type(DUCKDB_TYPE_UBIGINT);
    duckdb_logical_type bool_type = duckdb_create_logical_type(DUCKDB_TYPE_BOOLEAN);
    duckdb_state rc;
    if (!fn || !varchar_type || !ubigint_type || !bool_type) {
        if (fn) {
            duckdb_destroy_scalar_function(&fn);
        }
        if (varchar_type) {
            duckdb_destroy_logical_type(&varchar_type);
        }
        if (ubigint_type) {
            duckdb_destroy_logical_type(&ubigint_type);
        }
        if (bool_type) {
            duckdb_destroy_logical_type(&bool_type);
        }
        return false;
    }
    duckdb_scalar_function_set_name(fn, "rducks_register_scalar");
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, ubigint_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, bool_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_set_return_type(fn, bool_type);
    duckdb_scalar_function_set_volatile(fn);
    duckdb_scalar_function_set_extra_info(fn, runtime, NULL);
    duckdb_scalar_function_set_function(fn, rducks_register_scalar_scalar);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&varchar_type);
    duckdb_destroy_logical_type(&ubigint_type);
    duckdb_destroy_logical_type(&bool_type);
    return rc == DuckDBSuccess;
}

static bool rducks_register_unary_varchar_bool_surface(duckdb_connection con, rducks_runtime_entry_t *runtime,
                                                       const char *name, duckdb_scalar_function_t callback) {
    duckdb_scalar_function fn = duckdb_create_scalar_function();
    duckdb_logical_type varchar_type = duckdb_create_logical_type(DUCKDB_TYPE_VARCHAR);
    duckdb_logical_type bool_type = duckdb_create_logical_type(DUCKDB_TYPE_BOOLEAN);
    duckdb_state rc;
    if (!fn || !varchar_type || !bool_type) {
        if (fn) duckdb_destroy_scalar_function(&fn);
        if (varchar_type) duckdb_destroy_logical_type(&varchar_type);
        if (bool_type) duckdb_destroy_logical_type(&bool_type);
        return false;
    }
    duckdb_scalar_function_set_name(fn, name);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_set_return_type(fn, bool_type);
    duckdb_scalar_function_set_volatile(fn);
    duckdb_scalar_function_set_extra_info(fn, runtime, NULL);
    duckdb_scalar_function_set_function(fn, callback);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&varchar_type);
    duckdb_destroy_logical_type(&bool_type);
    return rc == DuckDBSuccess;
}

static bool rducks_register_binary_varchar_surface(duckdb_connection con, rducks_runtime_entry_t *runtime,
                                                   const char *name, duckdb_scalar_function_t callback) {
    duckdb_scalar_function fn = duckdb_create_scalar_function();
    duckdb_logical_type varchar_type = duckdb_create_logical_type(DUCKDB_TYPE_VARCHAR);
    duckdb_state rc;
    if (!fn || !varchar_type) {
        if (fn) duckdb_destroy_scalar_function(&fn);
        if (varchar_type) duckdb_destroy_logical_type(&varchar_type);
        return false;
    }
    duckdb_scalar_function_set_name(fn, name);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_set_return_type(fn, varchar_type);
    duckdb_scalar_function_set_volatile(fn);
    duckdb_scalar_function_set_extra_info(fn, runtime, NULL);
    duckdb_scalar_function_set_function(fn, callback);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&varchar_type);
    return rc == DuckDBSuccess;
}

static bool rducks_register_udf_stat_surface(duckdb_connection con, rducks_runtime_entry_t *runtime) {
    return rducks_register_binary_varchar_surface(con, runtime, "rducks_udf_stat", rducks_udf_stat_scalar);
}

static bool rducks_register_main_thread_token_surface(duckdb_connection con, rducks_runtime_entry_t *runtime) {
    return rducks_register_unary_varchar_bool_surface(con, runtime, "rducks_set_main_thread_token",
                                                      rducks_set_main_thread_token_scalar);
}

static bool rducks_register_execution_backend_surface(duckdb_connection con, rducks_runtime_entry_t *runtime) {
    return rducks_register_unary_varchar_bool_surface(con, runtime, "rducks_set_execution_backend",
                                                      rducks_set_execution_backend_scalar);
}

static bool rducks_register_noarg_scalar_ex(duckdb_connection con, rducks_runtime_entry_t *runtime,
                                             const char *name, duckdb_type return_type,
                                             duckdb_scalar_function_t callback, bool is_volatile) {
    duckdb_scalar_function fn = duckdb_create_scalar_function();
    duckdb_logical_type logical_type = duckdb_create_logical_type(return_type);
    duckdb_state rc;
    if (!fn || !logical_type) {
        if (fn) duckdb_destroy_scalar_function(&fn);
        if (logical_type) duckdb_destroy_logical_type(&logical_type);
        return false;
    }
    duckdb_scalar_function_set_name(fn, name);
    duckdb_scalar_function_set_return_type(fn, logical_type);
    if (is_volatile) duckdb_scalar_function_set_volatile(fn);
    if (runtime) duckdb_scalar_function_set_extra_info(fn, runtime, NULL);
    duckdb_scalar_function_set_function(fn, callback);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_logical_type(&logical_type);
    duckdb_destroy_scalar_function(&fn);
    return rc == DuckDBSuccess;
}

static bool rducks_register_noarg_scalar(duckdb_connection con, const char *name, duckdb_type return_type,
                                          duckdb_scalar_function_t callback, bool is_volatile) {
    return rducks_register_noarg_scalar_ex(con, NULL, name, return_type, callback, is_volatile);
}

static void rducks_queue_stat_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    uint64_t value = 0;
    idx_t n = duckdb_data_chunk_get_size(input);
    uint64_t *out = (uint64_t *)duckdb_vector_get_data(output);
    if (runtime) {
        rducks_queue_lock(runtime);
        value = runtime->queue_submitted;
        rducks_queue_unlock(runtime);
    }
    for (idx_t i = 0; i < n; i++) out[i] = value;
}

static void rducks_queue_executed_stat_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    uint64_t value = 0;
    idx_t n = duckdb_data_chunk_get_size(input);
    uint64_t *out = (uint64_t *)duckdb_vector_get_data(output);
    if (runtime) {
        rducks_queue_lock(runtime);
        value = runtime->queue_executed;
        rducks_queue_unlock(runtime);
    }
    for (idx_t i = 0; i < n; i++) out[i] = value;
}

static void rducks_queue_timeouts_stat_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    uint64_t value = 0;
    idx_t n = duckdb_data_chunk_get_size(input);
    uint64_t *out = (uint64_t *)duckdb_vector_get_data(output);
    if (runtime) {
        rducks_queue_lock(runtime);
        value = runtime->queue_timeouts;
        rducks_queue_unlock(runtime);
    }
    for (idx_t i = 0; i < n; i++) out[i] = value;
}

static void rducks_queue_self_test_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    uint64_t *iterations = (uint64_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 0));
    uint64_t *out = (uint64_t *)duckdb_vector_get_data(output);
    for (idx_t i = 0; i < n; i++) {
        char err[256];
        uint64_t value = 0;
        err[0] = '\0';
        if (!rducks_queue_self_test(runtime, iterations[i], &value, err, sizeof(err))) {
            duckdb_scalar_function_set_error(info, err[0] ? err : "Rducks queue self-test failed");
            return;
        }
        out[i] = value;
    }
}

static bool rducks_register_unary_ubigint_typed_surface(duckdb_connection con, rducks_runtime_entry_t *runtime,
                                                        const char *name, duckdb_type return_type,
                                                        duckdb_scalar_function_t callback) {
    duckdb_scalar_function fn = duckdb_create_scalar_function();
    duckdb_logical_type ubigint_type = duckdb_create_logical_type(DUCKDB_TYPE_UBIGINT);
    duckdb_logical_type out_type = duckdb_create_logical_type(return_type);
    duckdb_state rc;
    if (!fn || !ubigint_type || !out_type) {
        if (fn) duckdb_destroy_scalar_function(&fn);
        if (ubigint_type) duckdb_destroy_logical_type(&ubigint_type);
        if (out_type) duckdb_destroy_logical_type(&out_type);
        return false;
    }
    duckdb_scalar_function_set_name(fn, name);
    duckdb_scalar_function_add_parameter(fn, ubigint_type);
    duckdb_scalar_function_set_return_type(fn, out_type);
    duckdb_scalar_function_set_volatile(fn);
    duckdb_scalar_function_set_extra_info(fn, runtime, NULL);
    duckdb_scalar_function_set_function(fn, callback);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&ubigint_type);
    duckdb_destroy_logical_type(&out_type);
    return rc == DuckDBSuccess;
}

static bool rducks_register_unary_ubigint_surface(duckdb_connection con, rducks_runtime_entry_t *runtime,
                                                  const char *name, duckdb_scalar_function_t callback) {
    return rducks_register_unary_ubigint_typed_surface(con, runtime, name, DUCKDB_TYPE_UBIGINT, callback);
}

static void rducks_thread_is_main_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    bool *out = (bool *)duckdb_vector_get_data(output);
    bool is_main = runtime && rducks_is_main_thread(runtime);
    for (idx_t i = 0; i < n; i++) out[i] = is_main;
}

static bool rducks_register_queue_stats(duckdb_connection con, rducks_runtime_entry_t *runtime) {
    return rducks_register_noarg_scalar_ex(con, runtime, "rducks_queue_submitted", DUCKDB_TYPE_UBIGINT,
                                           rducks_queue_stat_scalar, true) &&
           rducks_register_noarg_scalar_ex(con, runtime, "rducks_queue_executed", DUCKDB_TYPE_UBIGINT,
                                           rducks_queue_executed_stat_scalar, true) &&
           rducks_register_noarg_scalar_ex(con, runtime, "rducks_queue_timeouts", DUCKDB_TYPE_UBIGINT,
                                           rducks_queue_timeouts_stat_scalar, true) &&
           rducks_register_unary_ubigint_surface(con, runtime, "rducks_queue_self_test",
                                                 rducks_queue_self_test_scalar) &&
           rducks_register_unary_ubigint_typed_surface(con, runtime, "rducks_thread_is_main",
                                                       DUCKDB_TYPE_BOOLEAN, rducks_thread_is_main_scalar);
}

static bool rducks_register_version(duckdb_connection con) {
    return rducks_register_noarg_scalar(con, "rducks_version", DUCKDB_TYPE_VARCHAR, rducks_version_scalar, false);
}

DUCKDB_EXTENSION_ENTRYPOINT(duckdb_connection connection,
                            duckdb_extension_info info,
                            struct duckdb_extension_access *access) {
    duckdb_database database = NULL;
    rducks_runtime_entry_t *runtime = NULL;
    char err[256];
    err[0] = '\0';

    if (access && info) {
        duckdb_database *db_ptr = access->get_database(info);
        if (db_ptr) {
            database = *db_ptr;
        }
    }
    runtime = rducks_runtime_get_or_create(database, err, sizeof(err));
    if (!runtime) {
        if (access) {
            access->set_error(info, err[0] ? err : "failed to initialize Rducks runtime");
        }
        return false;
    }

    rducks_runtime_lock();
    int ready = runtime->registration_surface_ready;
    rducks_runtime_unlock();
    if (!ready) {
        if (!rducks_register_version(connection) || !rducks_register_queue_stats(connection, runtime) ||
            !rducks_register_parallel_range(connection) || !rducks_register_parallel_thread_probe(connection, runtime) ||
            !rducks_register_main_thread_token_surface(connection, runtime) ||
            !rducks_register_execution_backend_surface(connection, runtime) || !rducks_register_udf_stat_surface(connection, runtime) ||
            !rducks_register_scalar_surface(connection, runtime)) {
            if (access) {
                access->set_error(info, "failed to register Rducks SQL surface");
            }
            return false;
        }
        rducks_runtime_lock();
        runtime->registration_surface_ready = 1;
        rducks_runtime_unlock();
    }
    return true;
}
