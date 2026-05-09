/* Included by ../rducks_extension.c. */

#ifndef _WIN32
#include <dlfcn.h>
#endif

static void rducks_arrow_error_to_buffer(duckdb_error_data error_data, const char *default_msg,
                                         char *err_msg, size_t err_cap) {
    const char *msg = NULL;
    if (error_data && duckdb_error_data_has_error(error_data)) {
        msg = duckdb_error_data_message(error_data);
    }
    snprintf(err_msg, err_cap, "%s", (msg && msg[0]) ? msg : default_msg);
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

static SEXP rducks_arrow_array_schema_or_expected_xptr(SEXP array_xptr, SEXP expected_schema_xptr) {
    /* Result arrays produced by some nanoarrow/R helpers carry their schema in
     * the external-pointer tag. When they do not, use the explicit schema that
     * registration computed for this UDF result. This is schema selection, not
     * a marshalling fallback to another execution path.
     */
    SEXP schema_xptr = R_ExternalPtrTag(array_xptr);
    if (schema_xptr == R_NilValue) return expected_schema_xptr;
    if (!Rf_inherits(schema_xptr, "nanoarrow_schema")) return expected_schema_xptr;
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
    result_schema_xptr = rducks_arrow_array_schema_or_expected_xptr(result_array_xptr, output_schema_xptr);
    result_schema = nanoarrow_schema_from_xptr(result_schema_xptr);
    return rducks_import_arrow_result_native(runtime, result_array, result_schema, return_desc, expected_size, output,
                                            err_msg, err_cap);
}

/* In-process single-thread R evaluator phases. These still use R/nanoarrow
 * external pointers and therefore must run on the recorded R thread. Later
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

typedef struct rducks_owned_bytes {
    uint8_t *data;
    size_t size;
} rducks_owned_bytes_t;

static void rducks_owned_bytes_reset(rducks_owned_bytes_t *bytes) {
    if (!bytes) return;
    free(bytes->data);
    bytes->data = NULL;
    bytes->size = 0;
}

static int rducks_ripc_bundle_valid(SEXP bundle) {
    return TYPEOF(bundle) == VECSXP && Rf_isFunction(rducks_named_list_get(bundle, "configure"));
}

static int rducks_ripc_read_string_scalar(SEXP x, const char *field, char **out,
                                          char *err_msg, size_t err_cap) {
    if (!Rf_isString(x) || XLENGTH(x) != 1 || STRING_ELT(x, 0) == NA_STRING || !CHAR(STRING_ELT(x, 0))[0]) {
        snprintf(err_msg, err_cap, "RIPC configure() must return a non-empty character scalar field '%s'", field);
        return 0;
    }
    *out = rducks_strdup_len(CHAR(STRING_ELT(x, 0)), strlen(CHAR(STRING_ELT(x, 0))));
    if (!*out) {
        snprintf(err_msg, err_cap, "out of memory copying RIPC configure() field '%s'", field);
        return 0;
    }
    return 1;
}

static int rducks_ripc_configure_meta_on_main(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                              SEXP bundle, char *err_msg, size_t err_cap) {
    SEXP configure = R_NilValue;
    SEXP output_schema_xptr = R_NilValue;
    SEXP call = R_NilValue;
    SEXP result = R_NilValue;
    SEXP endpoints_sexp = R_NilValue;
    SEXP udf_id_sexp = R_NilValue;
    SEXP timeout_sexp = R_NilValue;
    SEXP max_pending_sexp = R_NilValue;
    SEXP external_endpoints_sexp = R_NilValue;
    char **endpoints = NULL;
    char *udf_id = NULL;
    rducks_nng_client_pool_t *client_pool = NULL;
    int timeout_ms = 0;
    uint64_t max_pending = UINT64_MAX;
    int external_endpoints = 0;
    int protect_count = 0;
    int r_err = 0;
    R_xlen_t endpoint_count = 0;

    if (!runtime || !meta || !rducks_ripc_bundle_valid(bundle)) {
        snprintf(err_msg, err_cap, "RIPC metadata is invalid");
        return 0;
    }
    if (!rducks_is_main_thread(runtime)) {
        snprintf(err_msg, err_cap, "RIPC configure() must run on the recorded main R thread");
        return 0;
    }

    configure = rducks_named_list_get(bundle, "configure");
    output_schema_xptr = PROTECT(nanoarrow_schema_owning_xptr());
    protect_count++;
    if (!rducks_fill_output_arrow_schema(runtime, output_schema_xptr, meta, err_msg, err_cap)) goto fail;

    call = PROTECT(Rf_lang2(configure, output_schema_xptr));
    protect_count++;
    result = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, &r_err));
    protect_count++;
    if (r_err || Rf_inherits(result, "try-error")) {
        const char *detail = NULL;
        if (TYPEOF(result) == STRSXP && XLENGTH(result) > 0 && STRING_ELT(result, 0) != NA_STRING) {
            detail = CHAR(STRING_ELT(result, 0));
        }
        snprintf(err_msg, err_cap, "RIPC configure() failed%s%s",
                 (detail && detail[0]) ? ": " : "",
                 (detail && detail[0]) ? detail : "");
        goto fail;
    }
    if (TYPEOF(result) != VECSXP) {
        snprintf(err_msg, err_cap, "RIPC configure() must return a named list");
        goto fail;
    }

    endpoints_sexp = rducks_named_list_get(result, "endpoints");
    udf_id_sexp = rducks_named_list_get(result, "udf_id");
    timeout_sexp = rducks_named_list_get(result, "timeout_ms");
    max_pending_sexp = rducks_named_list_get(result, "max_pending");
    external_endpoints_sexp = rducks_named_list_get(result, "external_endpoints");
    if (!Rf_isString(endpoints_sexp) || XLENGTH(endpoints_sexp) < 1) {
        snprintf(err_msg, err_cap, "RIPC configure() must return character vector field 'endpoints'");
        goto fail;
    }
    endpoint_count = XLENGTH(endpoints_sexp);
    endpoints = (char **)calloc((size_t)endpoint_count, sizeof(char *));
    if (!endpoints) {
        snprintf(err_msg, err_cap, "out of memory copying RIPC endpoints");
        goto fail;
    }
    for (R_xlen_t i = 0; i < endpoint_count; i++) {
        SEXP endpoint = STRING_ELT(endpoints_sexp, i);
        const char *value;
        if (endpoint == NA_STRING || !CHAR(endpoint)[0]) {
            snprintf(err_msg, err_cap, "RIPC endpoint %lld is empty", (long long)i + 1LL);
            goto fail;
        }
        value = CHAR(endpoint);
        endpoints[i] = rducks_strdup_len(value, strlen(value));
        if (!endpoints[i]) {
            snprintf(err_msg, err_cap, "out of memory copying RIPC endpoint");
            goto fail;
        }
    }
    if (!rducks_ripc_read_string_scalar(udf_id_sexp, "udf_id", &udf_id, err_msg, err_cap)) goto fail;
    if (!Rf_isNull(timeout_sexp)) {
        double timeout_value = Rf_asReal(timeout_sexp);
        if (!R_finite(timeout_value) || timeout_value < 0 || timeout_value > (double)INT_MAX) {
            snprintf(err_msg, err_cap, "RIPC timeout_ms must be a non-negative integer-compatible value");
            goto fail;
        }
        timeout_ms = (int)timeout_value;
    }
    if (!Rf_isNull(max_pending_sexp)) {
        double max_pending_value = Rf_asReal(max_pending_sexp);
        if (R_finite(max_pending_value)) {
            if (max_pending_value < 1 || max_pending_value > (double)UINT64_MAX) {
                snprintf(err_msg, err_cap, "RIPC max_pending must be a positive integer-compatible value or Inf");
                goto fail;
            }
            max_pending = (uint64_t)max_pending_value;
        }
    }
    if (!Rf_isNull(external_endpoints_sexp)) {
        int value = Rf_asLogical(external_endpoints_sexp);
        external_endpoints = (value == TRUE) ? 1 : 0;
    }

    client_pool = rducks_nng_client_pool_new(endpoints, (size_t)endpoint_count, timeout_ms,
                                            max_pending, err_msg, err_cap);
    if (!client_pool) goto fail;

    rducks_nng_client_pool_destroy(&meta->ripc_client_pool);
    if (meta->ripc_endpoints) {
        for (size_t i = 0; i < meta->ripc_endpoint_count; i++) free(meta->ripc_endpoints[i]);
        free(meta->ripc_endpoints);
    }
    free(meta->ripc_udf_id);
    meta->ripc_endpoints = endpoints;
    meta->ripc_endpoint_count = (size_t)endpoint_count;
    meta->ripc_udf_id = udf_id;
    meta->ripc_timeout_ms = timeout_ms;
    meta->ripc_max_pending = max_pending;
    meta->ripc_external_endpoints = external_endpoints;
    meta->ripc_client_pool = client_pool;
    client_pool = NULL;
    atomic_store_explicit(&meta->ripc_next_endpoint, 0U, memory_order_relaxed);
    UNPROTECT(protect_count);
    return 1;

fail:
    rducks_nng_client_pool_destroy(&client_pool);
    if (endpoints) {
        for (R_xlen_t i = 0; i < endpoint_count; i++) free(endpoints[i]);
        free(endpoints);
    }
    free(udf_id);
    UNPROTECT(protect_count);
    return 0;
}

static void rducks_wire_put_u32(uint8_t *p, uint32_t value) {
    p[0] = (uint8_t)(value & 0xffU);
    p[1] = (uint8_t)((value >> 8) & 0xffU);
    p[2] = (uint8_t)((value >> 16) & 0xffU);
    p[3] = (uint8_t)((value >> 24) & 0xffU);
}

static void rducks_wire_put_u64(uint8_t *p, uint64_t value) {
    rducks_wire_put_u32(p, (uint32_t)(value & 0xffffffffULL));
    rducks_wire_put_u32(p + 4, (uint32_t)((value >> 32) & 0xffffffffULL));
}

static uint32_t rducks_wire_get_u32(const uint8_t *p) {
    return ((uint32_t)p[0]) | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t rducks_wire_get_u64(const uint8_t *p) {
    return ((uint64_t)rducks_wire_get_u32(p)) | ((uint64_t)rducks_wire_get_u32(p + 4) << 32);
}

static int rducks_ripc_build_execute_request(rducks_r_scalar_meta_t *meta, idx_t row_count,
                                             const uint8_t *payload, size_t payload_size,
                                             rducks_owned_bytes_t *request,
                                             char *err_msg, size_t err_cap) {
    size_t udf_len;
    size_t total;
    uint8_t *p;
    if (!meta || !meta->ripc_udf_id || !payload || !request) {
        snprintf(err_msg, err_cap, "RIPC request metadata is missing");
        return 0;
    }
    udf_len = strlen(meta->ripc_udf_id);
    if (udf_len > UINT32_MAX || row_count > (idx_t)UINT64_MAX || payload_size > (size_t)UINT64_MAX ||
        payload_size > SIZE_MAX - 36U - udf_len) {
        snprintf(err_msg, err_cap, "RIPC request is too large");
        return 0;
    }
    total = 36U + udf_len + payload_size;
    request->data = (uint8_t *)malloc(total ? total : 1U);
    if (!request->data) {
        snprintf(err_msg, err_cap, "out of memory allocating RIPC request");
        return 0;
    }
    request->size = total;
    p = request->data;
    memcpy(p, "RDK1", 4); p += 4;
    rducks_wire_put_u32(p, 1U); p += 4;
    rducks_wire_put_u32(p, 1U); p += 4;
    rducks_wire_put_u32(p, (uint32_t)udf_len); p += 4;
    rducks_wire_put_u32(p, 0U); p += 4;
    rducks_wire_put_u64(p, (uint64_t)row_count); p += 8;
    rducks_wire_put_u64(p, (uint64_t)payload_size); p += 8;
    if (udf_len) { memcpy(p, meta->ripc_udf_id, udf_len); p += udf_len; }
    if (payload_size) memcpy(p, payload, payload_size);
    return 1;
}

static int rducks_ripc_parse_response(const uint8_t *response, size_t response_size,
                                      const uint8_t **payload_out, size_t *payload_size_out,
                                      char *err_msg, size_t err_cap) {
    uint32_t version, type, status, error_len, reserved;
    uint64_t payload_len;
    size_t total;
    const uint8_t *p;
    if (payload_out) *payload_out = NULL;
    if (payload_size_out) *payload_size_out = 0;
    if (!response || response_size < 32U || memcmp(response, "RDK1", 4) != 0) {
        snprintf(err_msg, err_cap, "invalid RIPC response frame");
        return 0;
    }
    p = response + 4;
    version = rducks_wire_get_u32(p); p += 4;
    type = rducks_wire_get_u32(p); p += 4;
    status = rducks_wire_get_u32(p); p += 4;
    error_len = rducks_wire_get_u32(p); p += 4;
    reserved = rducks_wire_get_u32(p); p += 4;
    payload_len = rducks_wire_get_u64(p); p += 8;
    (void)reserved;
    if (version != 1U || type != 100U) {
        snprintf(err_msg, err_cap, "unsupported RIPC response frame");
        return 0;
    }
    if (payload_len > (uint64_t)SIZE_MAX || (size_t)payload_len > SIZE_MAX - 32U - (size_t)error_len) {
        snprintf(err_msg, err_cap, "RIPC response is too large");
        return 0;
    }
    total = 32U + (size_t)error_len + (size_t)payload_len;
    if (total != response_size) {
        snprintf(err_msg, err_cap, "truncated RIPC response frame");
        return 0;
    }
    if (status != 0U) {
        size_t n = (size_t)error_len;
        if (n >= err_cap) n = err_cap ? err_cap - 1U : 0U;
        if (err_cap > 0U) {
            if (n > 0U) memcpy(err_msg, p, n);
            err_msg[n] = '\0';
        }
        if (err_cap > 0U && err_msg[0] == '\0') snprintf(err_msg, err_cap, "RIPC worker returned an error");
        return 0;
    }
    p += error_len;
    *payload_out = p;
    *payload_size_out = (size_t)payload_len;
    return 1;
}

static int rducks_arrow_ipc_encode_input_chunk_native(rducks_runtime_entry_t *runtime,
                                                      rducks_r_scalar_meta_t *meta,
                                                      duckdb_data_chunk input,
                                                      rducks_owned_bytes_t *payload,
                                                      char *err_msg, size_t err_cap) {
    struct ArrowSchema schema;
    struct ArrowArray array;
    int ok = 0;
    memset(&schema, 0, sizeof(schema));
    memset(&array, 0, sizeof(array));
    if (!rducks_fill_input_arrow_schema_native(runtime, &schema, meta, err_msg, err_cap)) goto cleanup;
    if (!rducks_fill_input_arrow_array_native(runtime, &array, input, err_msg, err_cap)) goto cleanup;
    if (!rducks_arrow_ipc_encode_borrowed_array(&schema, &array, &payload->data, &payload->size, err_msg, err_cap)) goto cleanup;
    ok = 1;
cleanup:
    rducks_release_arrow_array_if_set(&array);
    rducks_release_arrow_schema_if_set(&schema);
    return ok;
}

static int rducks_import_arrow_ipc_result_bytes(rducks_runtime_entry_t *runtime,
                                                const uint8_t *payload, size_t payload_size,
                                                rducks_type_desc_t *return_desc, idx_t expected_size,
                                                duckdb_vector output, char *err_msg, size_t err_cap) {
    struct ArrowBuffer buffer;
    struct ArrowIpcInputStream input_stream;
    struct ArrowArrayStream array_stream;
    struct ArrowSchema schema;
    struct ArrowArray array;
    struct ArrowError error;
    int input_initialized = 0;
    int stream_initialized = 0;
    int ok = 0;

    ArrowBufferInit(&buffer);
    memset(&input_stream, 0, sizeof(input_stream));
    memset(&array_stream, 0, sizeof(array_stream));
    memset(&schema, 0, sizeof(schema));
    memset(&array, 0, sizeof(array));
    memset(&error, 0, sizeof(error));

    if (!payload || payload_size == 0U) {
        snprintf(err_msg, err_cap, "RIPC worker returned an empty Arrow IPC payload");
        goto cleanup;
    }
    if (ArrowBufferAppend(&buffer, payload, (int64_t)payload_size) != NANOARROW_OK) {
        snprintf(err_msg, err_cap, "out of memory copying RIPC Arrow IPC result bytes");
        goto cleanup;
    }
    if (ArrowIpcInputStreamInitBuffer(&input_stream, &buffer) != NANOARROW_OK) {
        snprintf(err_msg, err_cap, "ArrowIpcInputStreamInitBuffer() failed for RIPC result");
        goto cleanup;
    }
    input_initialized = 1;
    if (ArrowIpcArrayStreamReaderInit(&array_stream, &input_stream, NULL) != NANOARROW_OK) {
        snprintf(err_msg, err_cap, "ArrowIpcArrayStreamReaderInit() failed for RIPC result");
        goto cleanup;
    }
    input_initialized = 0;
    stream_initialized = 1;
    if (ArrowArrayStreamGetSchema(&array_stream, &schema, &error) != NANOARROW_OK) {
        snprintf(err_msg, err_cap, "RIPC result schema decode failed: %s", error.message[0] ? error.message : "unknown error");
        goto cleanup;
    }
    if (ArrowArrayStreamGetNext(&array_stream, &array, &error) != NANOARROW_OK) {
        snprintf(err_msg, err_cap, "RIPC result batch decode failed: %s", error.message[0] ? error.message : "unknown error");
        goto cleanup;
    }
    if (array.release == NULL) {
        snprintf(err_msg, err_cap, "RIPC result payload did not contain a record batch");
        goto cleanup;
    }
    if (!rducks_import_arrow_result_native(runtime, &array, &schema, return_desc, expected_size, output, err_msg, err_cap)) goto cleanup;
    ok = 1;

cleanup:
    rducks_release_arrow_array_if_set(&array);
    rducks_release_arrow_schema_if_set(&schema);
    if (stream_initialized && array_stream.release) array_stream.release(&array_stream);
    if (input_initialized && input_stream.release) input_stream.release(&input_stream);
    ArrowBufferReset(&buffer);
    return ok;
}

static int rducks_ripc_execute(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                               duckdb_data_chunk input, duckdb_vector output,
                               char *err_msg, size_t err_cap) {
    idx_t n;
    uint64_t endpoint_ticket;
    const char *endpoint;
    rducks_owned_bytes_t input_payload = {0};
    rducks_owned_bytes_t request = {0};
    uint8_t *response = NULL;
    size_t response_size = 0;
    const uint8_t *result_payload = NULL;
    size_t result_payload_size = 0;
    int ok = 0;

    if (!runtime || !meta) {
        snprintf(err_msg, err_cap, "RIPC execution metadata is missing");
        return 0;
    }
    if (!meta->ripc_endpoints || meta->ripc_endpoint_count == 0U || !meta->ripc_udf_id) {
        snprintf(err_msg, err_cap, "RIPC provider is not configured for this UDF");
        return 0;
    }
    n = duckdb_data_chunk_get_size(input);
    rducks_udf_record_evaluator(meta, n);
    if (!rducks_arrow_ipc_encode_input_chunk_native(runtime, meta, input, &input_payload, err_msg, err_cap)) goto cleanup;
    if (!rducks_ripc_build_execute_request(meta, n, input_payload.data, input_payload.size, &request, err_msg, err_cap)) goto cleanup;

    endpoint_ticket = atomic_fetch_add_explicit(&meta->ripc_next_endpoint, 1U, memory_order_relaxed);
    endpoint = meta->ripc_endpoints[endpoint_ticket % meta->ripc_endpoint_count];
    (void)endpoint_ticket;
    (void)endpoint;
    rducks_udf_record_ripc_inflight_add(meta);
    if (!rducks_nng_client_pool_request_reply(meta->ripc_client_pool, request.data, request.size,
                                             &response, &response_size, err_msg, err_cap)) {
        rducks_udf_record_ripc_inflight_done(meta, 1U);
        goto cleanup;
    }
    rducks_udf_record_ripc_inflight_done(meta, 1U);
    rducks_udf_record_ripc_submit_wave(meta, 1U);
    rducks_udf_record_ripc_collect_ready(meta, 1U);
    rducks_udf_record_ripc_batch(meta, 1U);
    if (!rducks_ripc_parse_response(response, response_size, &result_payload, &result_payload_size, err_msg, err_cap)) goto cleanup;
    if (!rducks_import_arrow_ipc_result_bytes(runtime, result_payload, result_payload_size,
                                             meta->return_desc, n, output, err_msg, err_cap)) goto cleanup;
    ok = 1;

cleanup:
    rducks_owned_bytes_reset(&input_payload);
    rducks_owned_bytes_reset(&request);
    free(response);
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
    const char *default_error;
    int ok;
} rducks_arrow_execute_context_t;

static void rducks_arrow_set_default_error(rducks_arrow_execute_context_t *ctx) {
    if (ctx && ctx->err_msg && ctx->err_cap > 0U && !ctx->err_msg[0] && ctx->default_error) {
        snprintf(ctx->err_msg, ctx->err_cap, "%s", ctx->default_error);
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
        rducks_arrow_set_default_error(ctx);
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
    rducks_arrow_set_default_error(ctx);
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
    ctx.default_error = "Rducks nanoarrow R function or marshal error";
    if (err_msg && err_cap > 0U) err_msg[0] = '\0';
    (void)R_tryCatchError(rducks_r_scalar_execute_try_body, &ctx,
                          rducks_arrow_execute_error_handler, &ctx);
    return ctx.ok;
}

static duckdb_data_chunk rducks_arrow_owned_result_chunk_new(rducks_r_scalar_meta_t *meta,
                                                             idx_t n,
                                                             char *err_msg, size_t err_cap) {
    duckdb_logical_type type;
    duckdb_data_chunk chunk;
    if (!meta || !meta->return_desc) {
        snprintf(err_msg, err_cap, "Rducks Arrow/R owned result chunk metadata missing");
        return NULL;
    }
    type = rducks_create_logical_type_for_desc(meta->return_desc);
    if (!type) {
        snprintf(err_msg, err_cap, "failed to allocate Rducks Arrow/R owned result logical type");
        return NULL;
    }
    chunk = duckdb_create_data_chunk(&type, 1);
    duckdb_destroy_logical_type(&type);
    if (!chunk) {
        snprintf(err_msg, err_cap, "failed to allocate Rducks Arrow/R owned result data chunk");
        return NULL;
    }
    duckdb_data_chunk_set_size(chunk, n);
    return chunk;
}

static int rducks_r_scalar_execute_to_owned_chunk(rducks_runtime_entry_t *runtime,
                                                  rducks_r_scalar_meta_t *meta,
                                                  duckdb_data_chunk input,
                                                  duckdb_vector output,
                                                  duckdb_data_chunk *chunk_out,
                                                  char *err_msg, size_t err_cap) {
    duckdb_data_chunk chunk;
    duckdb_vector chunk_output;
    (void)output;
    if (chunk_out) *chunk_out = NULL;
    if (!runtime || !meta || meta->eval_mode != RDUCKS_EVAL_R || !input || !chunk_out) {
        snprintf(err_msg, err_cap, "Rducks Arrow/R owned result chunk request is missing state");
        return 0;
    }
    chunk = rducks_arrow_owned_result_chunk_new(meta, duckdb_data_chunk_get_size(input), err_msg, err_cap);
    if (!chunk) return 0;
    chunk_output = duckdb_data_chunk_get_vector(chunk, 0);
    if (!chunk_output) {
        duckdb_destroy_data_chunk(&chunk);
        snprintf(err_msg, err_cap, "Rducks Arrow/R owned result chunk has no output vector");
        return 0;
    }
    if (!rducks_r_scalar_execute(runtime, meta, input, chunk_output, err_msg, err_cap)) {
        duckdb_destroy_data_chunk(&chunk);
        return 0;
    }
    *chunk_out = chunk;
    return 1;
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
            rducks_udf_record_dispatch(meta, duckdb_data_chunk_get_size(input), 0);
            if (!rducks_ripc_execute(runtime, meta, input, output, err_msg, sizeof(err_msg))) {
                duckdb_scalar_function_set_error(info, err_msg[0] ? err_msg : "Rducks native RIPC UDF failed");
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
        rducks_udf_record_dispatch(meta, duckdb_data_chunk_get_size(input), 0);
        if (!rducks_ripc_execute(runtime, meta, input, output, err_msg, sizeof(err_msg))) {
            duckdb_scalar_function_set_error(info, err_msg[0] ? err_msg : "Rducks native RIPC UDF failed");
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
            duckdb_scalar_function_set_error(info, err_msg[0] ? err_msg : "Rducks native RIPC UDF failed");
            return;
        }
        return;
    }

    if (!rducks_r_scalar_execute(runtime, meta, input, output, err_msg, sizeof(err_msg))) {
        duckdb_scalar_function_set_error(info, err_msg[0] ? err_msg : "Rducks scalar R function failed");
        return;
    }
}

