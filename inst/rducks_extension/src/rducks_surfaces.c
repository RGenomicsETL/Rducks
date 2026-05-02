/* Included by ../rducks_extension.c. */

static void rducks_version_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    (void)info;
    idx_t n = duckdb_data_chunk_get_size(input);
    for (idx_t i = 0; i < n; i++) {
        duckdb_vector_assign_string_element(output, i, "Rducks extension loaded");
    }
}

static bool rducks_register_scalar_surface(duckdb_connection con) {
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
    duckdb_scalar_function_set_return_type(fn, bool_type);
    duckdb_scalar_function_set_volatile(fn);
    duckdb_scalar_function_set_function(fn, rducks_register_scalar_scalar);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&varchar_type);
    duckdb_destroy_logical_type(&ubigint_type);
    duckdb_destroy_logical_type(&bool_type);
    return rc == DuckDBSuccess;
}

static bool rducks_register_main_thread_token_surface(duckdb_connection con) {
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
    duckdb_scalar_function_set_name(fn, "rducks_set_main_thread_token");
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_set_return_type(fn, bool_type);
    duckdb_scalar_function_set_volatile(fn);
    duckdb_scalar_function_set_function(fn, rducks_set_main_thread_token_scalar);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&varchar_type);
    duckdb_destroy_logical_type(&bool_type);
    return rc == DuckDBSuccess;
}

static bool rducks_register_noarg_scalar(duckdb_connection con, const char *name, duckdb_type return_type,
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
    duckdb_scalar_function_set_function(fn, callback);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_logical_type(&logical_type);
    duckdb_destroy_scalar_function(&fn);
    return rc == DuckDBSuccess;
}

static bool rducks_register_version(duckdb_connection con) {
    return rducks_register_noarg_scalar(con, "rducks_version", DUCKDB_TYPE_VARCHAR, rducks_version_scalar, false);
}

DUCKDB_EXTENSION_ENTRYPOINT_CUSTOM(duckdb_extension_info info, struct duckdb_extension_access *access) {
    duckdb_database database = NULL;
    if (access && info) {
        duckdb_database *db_ptr = access->get_database(info);
        if (db_ptr) {
            database = *db_ptr;
        }
    }
    if (!database) {
        if (access) {
            access->set_error(info, "failed to get database handle");
        }
        return false;
    }
    if (!g_connection || g_database != database) {
        if (duckdb_connect(database, &g_connection) == DuckDBError || !g_connection) {
            if (access) {
                access->set_error(info, "failed to open Rducks persistent connection");
            }
            return false;
        }
        g_database = database;
        g_registration_surface_ready = 0;
    }
    if (!g_registration_surface_ready) {
        if (!rducks_register_version(g_connection) || !rducks_register_main_thread_token_surface(g_connection) ||
            !rducks_register_scalar_surface(g_connection)) {
            if (access) {
                access->set_error(info, "failed to register Rducks SQL surface");
            }
            return false;
        }
        g_registration_surface_ready = 1;
    }
    return true;
}
