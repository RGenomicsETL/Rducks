/* Included by ../rducks_extension.c. */

#define RDUCKS_RC_BUNDLE_FUN 0
#define RDUCKS_RC_BUNDLE_ARG_TYPES 1
#define RDUCKS_RC_BUNDLE_RETURN_TYPE 2
#define RDUCKS_RC_BUNDLE_PREPARE_INPUTS 3
#define RDUCKS_RC_BUNDLE_CHECK_RETURN 4
#define RDUCKS_RC_BUNDLE_RESULT_ARRAY 5
#define RDUCKS_RC_BUNDLE_SIZE 6

static int rducks_rc_type_null_is_r_null(const rducks_type_desc_t *desc) {
    if (!desc) return 1;
    if (desc->kind != RDUCKS_KIND_SCALAR) return 1;
    switch (desc->scalar) {
    case RDUCKS_TYPE_I64:
    case RDUCKS_TYPE_U64:
    case RDUCKS_TYPE_BLOB:
    case RDUCKS_TYPE_HUGEINT:
    case RDUCKS_TYPE_UHUGEINT:
    case RDUCKS_TYPE_UUID:
    case RDUCKS_TYPE_INTERVAL:
    case RDUCKS_TYPE_BIT:
        return 1;
    default:
        return 0;
    }
}

static int rducks_rc_bundle_valid(SEXP bundle) {
    return TYPEOF(bundle) == VECSXP && XLENGTH(bundle) >= RDUCKS_RC_BUNDLE_SIZE &&
           Rf_isFunction(VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_FUN)) &&
           Rf_isFunction(VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_PREPARE_INPUTS)) &&
           Rf_isFunction(VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_CHECK_RETURN)) &&
           Rf_isFunction(VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_RESULT_ARRAY));
}

static SEXP rducks_rc_subset_with_bracket(SEXP values, idx_t row, int *ok) {
    int r_err = 0;
    SEXP idx = PROTECT(Rf_ScalarReal((double)row + 1.0));
    SEXP call = PROTECT(Rf_lang3(Rf_install("["), values, idx));
    SEXP out = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, &r_err));
    if (r_err) {
        *ok = 0;
        UNPROTECT(3);
        return R_NilValue;
    }
    UNPROTECT(3);
    return out;
}

static SEXP rducks_rc_vector_value_at(SEXP values, idx_t row, int *ok) {
    R_xlen_t i = (R_xlen_t)row;
    SEXP out;
    *ok = 1;
    if (values == R_NilValue) return R_NilValue;
    if (Rf_inherits(values, "rducks_decimal") || Rf_inherits(values, "rducks_interval")) {
        return rducks_rc_subset_with_bracket(values, row, ok);
    }
    switch (TYPEOF(values)) {
    case VECSXP:
        if (i < 0 || i >= XLENGTH(values)) {
            *ok = 0;
            return R_NilValue;
        }
        return VECTOR_ELT(values, i);
    case LGLSXP:
        if (i < 0 || i >= XLENGTH(values)) { *ok = 0; return R_NilValue; }
        out = PROTECT(Rf_allocVector(LGLSXP, 1));
        LOGICAL(out)[0] = LOGICAL(values)[i];
        Rf_copyMostAttrib(values, out);
        UNPROTECT(1);
        return out;
    case INTSXP:
        if (i < 0 || i >= XLENGTH(values)) { *ok = 0; return R_NilValue; }
        out = PROTECT(Rf_allocVector(INTSXP, 1));
        INTEGER(out)[0] = INTEGER(values)[i];
        Rf_copyMostAttrib(values, out);
        UNPROTECT(1);
        return out;
    case REALSXP:
        if (i < 0 || i >= XLENGTH(values)) { *ok = 0; return R_NilValue; }
        out = PROTECT(Rf_allocVector(REALSXP, 1));
        REAL(out)[0] = REAL(values)[i];
        Rf_copyMostAttrib(values, out);
        UNPROTECT(1);
        return out;
    case STRSXP:
        if (i < 0 || i >= XLENGTH(values)) { *ok = 0; return R_NilValue; }
        out = PROTECT(Rf_allocVector(STRSXP, 1));
        SET_STRING_ELT(out, 0, STRING_ELT(values, i));
        Rf_copyMostAttrib(values, out);
        UNPROTECT(1);
        return out;
    case RAWSXP:
        if (i < 0 || i >= XLENGTH(values)) { *ok = 0; return R_NilValue; }
        out = PROTECT(Rf_allocVector(RAWSXP, 1));
        RAW(out)[0] = RAW(values)[i];
        Rf_copyMostAttrib(values, out);
        UNPROTECT(1);
        return out;
    default:
        return rducks_rc_subset_with_bracket(values, row, ok);
    }
}

static int rducks_rc_logical_at(SEXP x, idx_t row) {
    if (TYPEOF(x) != LGLSXP || (R_xlen_t)row < 0 || (R_xlen_t)row >= XLENGTH(x)) return 0;
    return LOGICAL(x)[(R_xlen_t)row] == TRUE;
}

static SEXP rducks_rc_arg_at(const rducks_type_desc_t *type, SEXP values, SEXP nulls, idx_t row, int *ok) {
    if (rducks_rc_logical_at(nulls, row) && rducks_rc_type_null_is_r_null(type)) {
        *ok = 1;
        return R_NilValue;
    }
    return rducks_rc_vector_value_at(values, row, ok);
}

static SEXP rducks_rc_call_user(SEXP fun, SEXP args, int *r_err) {
    SEXP call = PROTECT(Rf_lcons(fun, args));
    SEXP value = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, r_err));
    UNPROTECT(2);
    return value;
}

static SEXP rducks_rc_check_return(SEXP check_return_fun, SEXP return_type, SEXP value, int *r_err) {
    SEXP call = PROTECT(Rf_lang3(check_return_fun, return_type, value));
    SEXP checked = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, r_err));
    UNPROTECT(2);
    return checked;
}

static int rducks_rc_scalar_execute(rducks_r_scalar_meta_t *meta, duckdb_data_chunk input, duckdb_vector output,
                                    char *err_msg, size_t err_cap) {
    idx_t n;
    int protect_count = 0;
    int r_err = 0;
    SEXP bundle;
    SEXP fun;
    SEXP arg_types;
    SEXP return_type;
    SEXP prepare_inputs_fun;
    SEXP check_return_fun;
    SEXP result_array_fun;
    SEXP input_schema_xptr;
    SEXP input_array_xptr;
    SEXP output_schema_xptr;
    SEXP n_sexp;
    SEXP prep_call;
    SEXP prepared;
    SEXP columns;
    SEXP nulls;
    SEXP top_level_null;
    SEXP results;
    SEXP result_call;
    SEXP result_array;

    if (!meta || !meta->fun || meta->fun == R_NilValue) {
        snprintf(err_msg, err_cap, "Rducks RC scalar metadata missing");
        return 0;
    }
    bundle = meta->fun;
    if (!rducks_rc_bundle_valid(bundle)) {
        snprintf(err_msg, err_cap, "Rducks RC scalar metadata bundle is invalid");
        return 0;
    }

    fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_FUN);
    arg_types = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_ARG_TYPES);
    return_type = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_RETURN_TYPE);
    prepare_inputs_fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_PREPARE_INPUTS);
    check_return_fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_CHECK_RETURN);
    result_array_fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_RESULT_ARRAY);

    n = duckdb_data_chunk_get_size(input);
    input_schema_xptr = PROTECT(nanoarrow_schema_owning_xptr());
    protect_count++;
    if (!rducks_fill_input_arrow_schema(input_schema_xptr, meta, err_msg, err_cap)) goto fail;

    input_array_xptr = PROTECT(nanoarrow_array_owning_xptr());
    protect_count++;
    if (!rducks_fill_input_arrow_array(input_array_xptr, input, err_msg, err_cap)) goto fail;
    R_SetExternalPtrTag(input_array_xptr, input_schema_xptr);

    output_schema_xptr = PROTECT(nanoarrow_schema_owning_xptr());
    protect_count++;
    if (!rducks_fill_output_arrow_schema(output_schema_xptr, meta, err_msg, err_cap)) goto fail;

    n_sexp = PROTECT(Rf_ScalarReal((double)n));
    protect_count++;
    prep_call = PROTECT(Rf_lang5(prepare_inputs_fun, arg_types, input_array_xptr, input_schema_xptr, n_sexp));
    protect_count++;
    prepared = PROTECT(R_tryEvalSilent(prep_call, R_GlobalEnv, &r_err));
    protect_count++;
    if (r_err || TYPEOF(prepared) != VECSXP || XLENGTH(prepared) < 3) {
        snprintf(err_msg, err_cap, "Rducks RC input preparation failed");
        goto fail;
    }
    columns = VECTOR_ELT(prepared, 0);
    nulls = VECTOR_ELT(prepared, 1);
    top_level_null = VECTOR_ELT(prepared, 2);
    if (TYPEOF(columns) != VECSXP || TYPEOF(nulls) != VECSXP || TYPEOF(top_level_null) != LGLSXP) {
        snprintf(err_msg, err_cap, "Rducks RC input preparation returned invalid metadata");
        goto fail;
    }

    results = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)n));
    protect_count++;
    for (idx_t row = 0; row < n; row++) {
        if (meta->null_handling == RDUCKS_NULL_DEFAULT && rducks_rc_logical_at(top_level_null, row)) {
            SET_VECTOR_ELT(results, (R_xlen_t)row, R_NilValue);
            continue;
        }

        SEXP args = PROTECT(Rf_allocList((int)meta->arity));
        SEXP node = args;
        for (size_t col = 0; col < meta->arity; col++) {
            int ok = 1;
            SEXP arg = rducks_rc_arg_at(meta->args[col], VECTOR_ELT(columns, (R_xlen_t)col),
                                        VECTOR_ELT(nulls, (R_xlen_t)col), row, &ok);
            if (!ok) {
                UNPROTECT(1);
                snprintf(err_msg, err_cap, "Rducks RC argument extraction failed");
                goto fail;
            }
            PROTECT(arg);
            SETCAR(node, arg);
            UNPROTECT(1);
            node = CDR(node);
        }

        r_err = 0;
        SEXP value = PROTECT(rducks_rc_call_user(fun, args, &r_err));
        UNPROTECT(1); /* args */
        if (r_err) {
            UNPROTECT(1); /* value */
            if (meta->exception_handling == RDUCKS_EXCEPTION_RETURN_NULL) {
                SET_VECTOR_ELT(results, (R_xlen_t)row, R_NilValue);
                continue;
            }
            snprintf(err_msg, err_cap, "Rducks RC R function error");
            goto fail;
        }

        r_err = 0;
        SEXP checked = PROTECT(rducks_rc_check_return(check_return_fun, return_type, value, &r_err));
        UNPROTECT(1); /* value */
        if (r_err) {
            UNPROTECT(1); /* checked */
            snprintf(err_msg, err_cap, "Rducks RC return validation or marshal error");
            goto fail;
        }
        SET_VECTOR_ELT(results, (R_xlen_t)row, checked);
        UNPROTECT(1); /* checked */
    }

    result_call = PROTECT(Rf_lang5(result_array_fun, return_type, results, output_schema_xptr, n_sexp));
    protect_count++;
    r_err = 0;
    result_array = PROTECT(R_tryEvalSilent(result_call, R_GlobalEnv, &r_err));
    protect_count++;
    if (r_err) {
        snprintf(err_msg, err_cap, "Rducks RC Arrow result construction failed");
        goto fail;
    }
    if (!rducks_import_arrow_result(result_array, output_schema_xptr, meta->return_desc, n, output, err_msg, err_cap)) goto fail;

    UNPROTECT(protect_count);
    return 1;

fail:
    UNPROTECT(protect_count);
    return 0;
}
