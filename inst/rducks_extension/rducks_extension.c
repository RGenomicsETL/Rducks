/* Rducks DuckDB extension
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "duckdb_extension.h"

#include <R.h>
#include <Rinternals.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

DUCKDB_EXTENSION_EXTERN

static duckdb_database g_database = NULL;
static duckdb_connection g_connection = NULL;
static int g_registration_surface_ready = 0;

typedef struct rducks_r_f64_meta {
    SEXP fun;
    int arity;
} rducks_r_f64_meta_t;

static char *rducks_copy_duckdb_string(duckdb_string_t *s) {
    uint32_t len = duckdb_string_t_length(*s);
    const char *data = duckdb_string_t_data(s);
    char *out = (char *)malloc((size_t)len + 1U);
    if (!out) {
        return NULL;
    }
    memcpy(out, data, (size_t)len);
    out[len] = '\0';
    return out;
}

static void rducks_r_f64_meta_destroy(void *ptr) {
    rducks_r_f64_meta_t *meta = (rducks_r_f64_meta_t *)ptr;
    if (!meta) {
        return;
    }
    if (meta->fun != R_NilValue) {
        R_ReleaseObject(meta->fun);
    }
    free(meta);
}

static void rducks_version_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    (void)info;
    idx_t n = duckdb_data_chunk_get_size(input);
    for (idx_t i = 0; i < n; i++) {
        duckdb_vector_assign_string_element(output, i, "Rducks extension loaded");
    }
}

static void rducks_r_f64_udf(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_r_f64_meta_t *meta = (rducks_r_f64_meta_t *)duckdb_scalar_function_get_extra_info(info);
    if (!meta || !meta->fun) {
        duckdb_scalar_function_set_error(info, "Rducks callback metadata missing");
        return;
    }

    idx_t n = duckdb_data_chunk_get_size(input);
    double *out = (double *)duckdb_vector_get_data(output);
    double *arg0 = NULL;
    double *arg1 = NULL;
    if (meta->arity >= 1) {
        arg0 = (double *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 0));
    }
    if (meta->arity >= 2) {
        arg1 = (double *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 1));
    }

    for (idx_t i = 0; i < n; i++) {
        SEXP call = R_NilValue;
        int err = 0;
        if (meta->arity == 1) {
            SEXP a0 = PROTECT(Rf_ScalarReal(arg0[i]));
            call = PROTECT(Rf_lang2(meta->fun, a0));
            SEXP res = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, &err));
            if (err) {
                UNPROTECT(3);
                duckdb_scalar_function_set_error(info, "R callback raised an error");
                return;
            }
            out[i] = Rf_asReal(res);
            UNPROTECT(3);
        } else if (meta->arity == 2) {
            SEXP a0 = PROTECT(Rf_ScalarReal(arg0[i]));
            SEXP a1 = PROTECT(Rf_ScalarReal(arg1[i]));
            call = PROTECT(Rf_lang3(meta->fun, a0, a1));
            SEXP res = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, &err));
            if (err) {
                UNPROTECT(4);
                duckdb_scalar_function_set_error(info, "R callback raised an error");
                return;
            }
            out[i] = Rf_asReal(res);
            UNPROTECT(4);
        } else {
            duckdb_scalar_function_set_error(info, "unsupported Rducks f64 callback arity");
            return;
        }
    }
}

static bool rducks_register_r_f64(const char *name, SEXP fun, int arity) {
    if (!g_connection || !name || !name[0] || !Rf_isFunction(fun) || arity < 1 || arity > 2) {
        return false;
    }

    duckdb_scalar_function fn = duckdb_create_scalar_function();
    duckdb_logical_type double_type = duckdb_create_logical_type(DUCKDB_TYPE_DOUBLE);
    rducks_r_f64_meta_t *meta = NULL;
    duckdb_state rc;
    if (!fn || !double_type) {
        if (fn) duckdb_destroy_scalar_function(&fn);
        if (double_type) duckdb_destroy_logical_type(&double_type);
        return false;
    }

    meta = (rducks_r_f64_meta_t *)calloc(1, sizeof(rducks_r_f64_meta_t));
    if (!meta) {
        duckdb_destroy_scalar_function(&fn);
        duckdb_destroy_logical_type(&double_type);
        return false;
    }
    meta->fun = fun;
    meta->arity = arity;
    R_PreserveObject(fun);

    duckdb_scalar_function_set_name(fn, name);
    for (int i = 0; i < arity; i++) {
        duckdb_scalar_function_add_parameter(fn, double_type);
    }
    duckdb_scalar_function_set_return_type(fn, double_type);
    duckdb_scalar_function_set_volatile(fn);
    duckdb_scalar_function_set_extra_info(fn, meta, rducks_r_f64_meta_destroy);
    duckdb_scalar_function_set_function(fn, rducks_r_f64_udf);

    rc = duckdb_register_scalar_function(g_connection, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&double_type);
    return rc == DuckDBSuccess;
}

static void rducks_register_f64_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    idx_t n = duckdb_data_chunk_get_size(input);
    duckdb_string_t *names = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 0));
    uint64_t *fun_ptrs = (uint64_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 1));
    int32_t *arities = (int32_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 2));
    bool *out = (bool *)duckdb_vector_get_data(output);

    for (idx_t i = 0; i < n; i++) {
        char *name = rducks_copy_duckdb_string(&names[i]);
        if (!name) {
            duckdb_scalar_function_set_error(info, "out of memory");
            return;
        }
        SEXP fun = (SEXP)(uintptr_t)fun_ptrs[i];
        out[i] = rducks_register_r_f64(name, fun, arities[i]);
        free(name);
    }
}

static bool rducks_register_scalar_surface(duckdb_connection con) {
    duckdb_scalar_function fn = duckdb_create_scalar_function();
    duckdb_logical_type varchar_type = duckdb_create_logical_type(DUCKDB_TYPE_VARCHAR);
    duckdb_logical_type ubigint_type = duckdb_create_logical_type(DUCKDB_TYPE_UBIGINT);
    duckdb_logical_type integer_type = duckdb_create_logical_type(DUCKDB_TYPE_INTEGER);
    duckdb_logical_type bool_type = duckdb_create_logical_type(DUCKDB_TYPE_BOOLEAN);
    duckdb_state rc;
    if (!fn || !varchar_type || !ubigint_type || !integer_type || !bool_type) {
        if (fn) duckdb_destroy_scalar_function(&fn);
        if (varchar_type) duckdb_destroy_logical_type(&varchar_type);
        if (ubigint_type) duckdb_destroy_logical_type(&ubigint_type);
        if (integer_type) duckdb_destroy_logical_type(&integer_type);
        if (bool_type) duckdb_destroy_logical_type(&bool_type);
        return false;
    }
    duckdb_scalar_function_set_name(fn, "rducks_register_f64");
    duckdb_scalar_function_add_parameter(fn, varchar_type);
    duckdb_scalar_function_add_parameter(fn, ubigint_type);
    duckdb_scalar_function_add_parameter(fn, integer_type);
    duckdb_scalar_function_set_return_type(fn, bool_type);
    duckdb_scalar_function_set_volatile(fn);
    duckdb_scalar_function_set_function(fn, rducks_register_f64_scalar);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_scalar_function(&fn);
    duckdb_destroy_logical_type(&varchar_type);
    duckdb_destroy_logical_type(&ubigint_type);
    duckdb_destroy_logical_type(&integer_type);
    duckdb_destroy_logical_type(&bool_type);
    return rc == DuckDBSuccess;
}

static bool rducks_register_version(duckdb_connection con) {
    duckdb_scalar_function fn = duckdb_create_scalar_function();
    duckdb_logical_type varchar_type = duckdb_create_logical_type(DUCKDB_TYPE_VARCHAR);
    duckdb_state rc;
    if (!fn || !varchar_type) {
        if (fn) duckdb_destroy_scalar_function(&fn);
        if (varchar_type) duckdb_destroy_logical_type(&varchar_type);
        return false;
    }
    duckdb_scalar_function_set_name(fn, "rducks_version");
    duckdb_scalar_function_set_return_type(fn, varchar_type);
    duckdb_scalar_function_set_function(fn, rducks_version_scalar);
    rc = duckdb_register_scalar_function(con, fn);
    duckdb_destroy_logical_type(&varchar_type);
    duckdb_destroy_scalar_function(&fn);
    return rc == DuckDBSuccess;
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
        if (access) access->set_error(info, "failed to get database handle");
        return false;
    }
    if (!g_connection || g_database != database) {
        if (duckdb_connect(database, &g_connection) == DuckDBError || !g_connection) {
            if (access) access->set_error(info, "failed to open Rducks persistent connection");
            return false;
        }
        g_database = database;
        g_registration_surface_ready = 0;
    }
    if (!g_registration_surface_ready) {
        if (!rducks_register_version(g_connection) || !rducks_register_scalar_surface(g_connection)) {
            if (access) access->set_error(info, "failed to register Rducks SQL surface");
            return false;
        }
        g_registration_surface_ready = 1;
    }
    return true;
}
