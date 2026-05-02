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


static int rducks_rc_direct_type_supported(const rducks_type_desc_t *desc) {
    if (!desc || desc->kind != RDUCKS_KIND_SCALAR) return 0;
    switch (desc->scalar) {
    case RDUCKS_TYPE_BOOL:
    case RDUCKS_TYPE_I8:
    case RDUCKS_TYPE_U8:
    case RDUCKS_TYPE_I16:
    case RDUCKS_TYPE_U16:
    case RDUCKS_TYPE_I32:
    case RDUCKS_TYPE_U32:
    case RDUCKS_TYPE_F32:
    case RDUCKS_TYPE_F64:
    case RDUCKS_TYPE_VARCHAR:
    case RDUCKS_TYPE_BLOB:
    case RDUCKS_TYPE_DATE:
    case RDUCKS_TYPE_TIME:
    case RDUCKS_TYPE_TIMESTAMP:
        return 1;
    default:
        return 0;
    }
}

static int rducks_rc_direct_supported(rducks_r_scalar_meta_t *meta) {
    if (!meta || !rducks_rc_direct_type_supported(meta->return_desc)) return 0;
    for (size_t i = 0; i < meta->arity; i++) {
        if (!rducks_rc_direct_type_supported(meta->args[i])) return 0;
    }
    return 1;
}

typedef struct rducks_rc_direct_vector_view {
    duckdb_vector vector;
    void *data;
    uint64_t *validity;
} rducks_rc_direct_vector_view_t;

static void rducks_rc_direct_input_view_init(rducks_rc_direct_vector_view_t *view, duckdb_vector vector) {
    view->vector = vector;
    view->data = duckdb_vector_get_data(vector);
    view->validity = duckdb_vector_get_validity(vector);
}

static void rducks_rc_direct_output_view_init(rducks_rc_direct_vector_view_t *view, duckdb_vector vector) {
    view->vector = vector;
    view->data = duckdb_vector_get_data(vector);
    view->validity = duckdb_vector_get_validity(vector);
}

static int rducks_rc_direct_view_valid_at(const rducks_rc_direct_vector_view_t *view, idx_t row) {
    if (!view->validity) return 1;
    return duckdb_validity_row_is_valid(view->validity, row) ? 1 : 0;
}

static void rducks_rc_output_set_null(rducks_rc_direct_vector_view_t *output, idx_t row) {
    if (!output->validity) {
        duckdb_vector_ensure_validity_writable(output->vector);
        output->validity = duckdb_vector_get_validity(output->vector);
    }
    duckdb_validity_set_row_invalid(output->validity, row);
}

static void rducks_rc_output_set_valid_if_needed(rducks_rc_direct_vector_view_t *output, idx_t row) {
    if (output->validity) duckdb_validity_set_row_valid(output->validity, row);
}

static SEXP rducks_rc_make_date(double days) {
    SEXP out = PROTECT(Rf_allocVector(REALSXP, 1));
    SEXP cls = PROTECT(Rf_mkString("Date"));
    REAL(out)[0] = days;
    Rf_setAttrib(out, R_ClassSymbol, cls);
    UNPROTECT(2);
    return out;
}

static SEXP rducks_rc_make_timestamp(double seconds) {
    SEXP out = PROTECT(Rf_allocVector(REALSXP, 1));
    SEXP cls = PROTECT(Rf_allocVector(STRSXP, 2));
    SEXP tzone = PROTECT(Rf_mkString("UTC"));
    REAL(out)[0] = seconds;
    SET_STRING_ELT(cls, 0, Rf_mkChar("POSIXct"));
    SET_STRING_ELT(cls, 1, Rf_mkChar("POSIXt"));
    Rf_setAttrib(out, R_ClassSymbol, cls);
    Rf_setAttrib(out, Rf_install("tzone"), tzone);
    UNPROTECT(3);
    return out;
}

static SEXP rducks_rc_missing_arg(const rducks_type_desc_t *desc) {
    SEXP out;
    switch (desc->scalar) {
    case RDUCKS_TYPE_BOOL:
        out = PROTECT(Rf_allocVector(LGLSXP, 1));
        LOGICAL(out)[0] = NA_LOGICAL;
        UNPROTECT(1);
        return out;
    case RDUCKS_TYPE_I8:
    case RDUCKS_TYPE_U8:
    case RDUCKS_TYPE_I16:
    case RDUCKS_TYPE_U16:
    case RDUCKS_TYPE_I32:
        out = PROTECT(Rf_allocVector(INTSXP, 1));
        INTEGER(out)[0] = NA_INTEGER;
        UNPROTECT(1);
        return out;
    case RDUCKS_TYPE_U32:
    case RDUCKS_TYPE_F32:
    case RDUCKS_TYPE_F64:
    case RDUCKS_TYPE_TIME:
        out = PROTECT(Rf_allocVector(REALSXP, 1));
        REAL(out)[0] = NA_REAL;
        UNPROTECT(1);
        return out;
    case RDUCKS_TYPE_VARCHAR:
        out = PROTECT(Rf_allocVector(STRSXP, 1));
        SET_STRING_ELT(out, 0, NA_STRING);
        UNPROTECT(1);
        return out;
    case RDUCKS_TYPE_DATE:
        return rducks_rc_make_date(NA_REAL);
    case RDUCKS_TYPE_TIMESTAMP:
        return rducks_rc_make_timestamp(NA_REAL);
    case RDUCKS_TYPE_BLOB:
    default:
        return R_NilValue;
    }
}

static SEXP rducks_rc_direct_arg(const rducks_type_desc_t *desc, const rducks_rc_direct_vector_view_t *input, idx_t row) {
    SEXP out;
    if (!rducks_rc_direct_view_valid_at(input, row)) return rducks_rc_missing_arg(desc);
    switch (desc->scalar) {
    case RDUCKS_TYPE_BOOL: {
        bool *data = (bool *)input->data;
        out = PROTECT(Rf_allocVector(LGLSXP, 1));
        LOGICAL(out)[0] = data[row] ? TRUE : FALSE;
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_I8: {
        int8_t *data = (int8_t *)input->data;
        out = PROTECT(Rf_allocVector(INTSXP, 1));
        INTEGER(out)[0] = (int)data[row];
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_U8: {
        uint8_t *data = (uint8_t *)input->data;
        out = PROTECT(Rf_allocVector(INTSXP, 1));
        INTEGER(out)[0] = (int)data[row];
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_I16: {
        int16_t *data = (int16_t *)input->data;
        out = PROTECT(Rf_allocVector(INTSXP, 1));
        INTEGER(out)[0] = (int)data[row];
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_U16: {
        uint16_t *data = (uint16_t *)input->data;
        out = PROTECT(Rf_allocVector(INTSXP, 1));
        INTEGER(out)[0] = (int)data[row];
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_I32: {
        int32_t *data = (int32_t *)input->data;
        out = PROTECT(Rf_allocVector(INTSXP, 1));
        INTEGER(out)[0] = (int)data[row];
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_U32: {
        uint32_t *data = (uint32_t *)input->data;
        out = PROTECT(Rf_allocVector(REALSXP, 1));
        REAL(out)[0] = (double)data[row];
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_F32: {
        float *data = (float *)input->data;
        out = PROTECT(Rf_allocVector(REALSXP, 1));
        REAL(out)[0] = (double)data[row];
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_F64: {
        double *data = (double *)input->data;
        out = PROTECT(Rf_allocVector(REALSXP, 1));
        REAL(out)[0] = data[row];
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_VARCHAR: {
        duckdb_string_t *data = (duckdb_string_t *)input->data;
        uint32_t len = duckdb_string_t_length(data[row]);
        const char *ptr = duckdb_string_t_data(&data[row]);
        out = PROTECT(Rf_allocVector(STRSXP, 1));
        SET_STRING_ELT(out, 0, Rf_mkCharLenCE(ptr, (int)len, CE_UTF8));
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_BLOB: {
        duckdb_string_t *data = (duckdb_string_t *)input->data;
        uint32_t len = duckdb_string_t_length(data[row]);
        const char *ptr = duckdb_string_t_data(&data[row]);
        out = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)len));
        if (len) memcpy(RAW(out), ptr, len);
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_DATE: {
        duckdb_date *data = (duckdb_date *)input->data;
        return rducks_rc_make_date((double)data[row].days);
    }
    case RDUCKS_TYPE_TIME: {
        duckdb_time *data = (duckdb_time *)input->data;
        out = PROTECT(Rf_allocVector(REALSXP, 1));
        REAL(out)[0] = (double)data[row].micros / 1000000.0;
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_TIMESTAMP: {
        duckdb_timestamp *data = (duckdb_timestamp *)input->data;
        return rducks_rc_make_timestamp((double)data[row].micros / 1000000.0);
    }
    default:
        return R_NilValue;
    }
}

static int rducks_rc_value_is_null_for_output(const rducks_type_desc_t *desc, SEXP value) {
    if (value == R_NilValue) return 1;
    if (desc->scalar == RDUCKS_TYPE_F32 || desc->scalar == RDUCKS_TYPE_F64) {
        if (TYPEOF(value) != REALSXP || XLENGTH(value) < 1) return 0;
        return ISNA(REAL(value)[0]);
    }
    if (desc->scalar == RDUCKS_TYPE_VARCHAR) {
        return TYPEOF(value) == STRSXP && XLENGTH(value) > 0 && STRING_ELT(value, 0) == NA_STRING;
    }
    if (desc->scalar == RDUCKS_TYPE_BLOB) return 0;
    if (TYPEOF(value) == INTSXP && XLENGTH(value) > 0) return INTEGER(value)[0] == NA_INTEGER;
    if (TYPEOF(value) == LGLSXP && XLENGTH(value) > 0) return LOGICAL(value)[0] == NA_LOGICAL;
    if (TYPEOF(value) == REALSXP && XLENGTH(value) > 0) return ISNA(REAL(value)[0]);
    return 0;
}

static int rducks_rc_write_direct_output(const rducks_type_desc_t *desc, rducks_rc_direct_vector_view_t *output,
                                         idx_t row, SEXP value, char *err_msg, size_t err_cap) {
    if (rducks_rc_value_is_null_for_output(desc, value)) {
        rducks_rc_output_set_null(output, row);
        return 1;
    }
    rducks_rc_output_set_valid_if_needed(output, row);
    switch (desc->scalar) {
    case RDUCKS_TYPE_BOOL:
        ((bool *)output->data)[row] = Rf_asLogical(value) == TRUE;
        return 1;
    case RDUCKS_TYPE_I8:
        ((int8_t *)output->data)[row] = (int8_t)Rf_asInteger(value);
        return 1;
    case RDUCKS_TYPE_U8:
        ((uint8_t *)output->data)[row] = (uint8_t)Rf_asInteger(value);
        return 1;
    case RDUCKS_TYPE_I16:
        ((int16_t *)output->data)[row] = (int16_t)Rf_asInteger(value);
        return 1;
    case RDUCKS_TYPE_U16:
        ((uint16_t *)output->data)[row] = (uint16_t)Rf_asInteger(value);
        return 1;
    case RDUCKS_TYPE_I32:
        ((int32_t *)output->data)[row] = (int32_t)Rf_asInteger(value);
        return 1;
    case RDUCKS_TYPE_U32:
        ((uint32_t *)output->data)[row] = (uint32_t)Rf_asReal(value);
        return 1;
    case RDUCKS_TYPE_F32:
        ((float *)output->data)[row] = (float)Rf_asReal(value);
        return 1;
    case RDUCKS_TYPE_F64:
        ((double *)output->data)[row] = Rf_asReal(value);
        return 1;
    case RDUCKS_TYPE_VARCHAR: {
        if (TYPEOF(value) != STRSXP || XLENGTH(value) < 1) {
            snprintf(err_msg, err_cap, "Rducks RC VARCHAR output is not a character scalar");
            return 0;
        }
        SEXP ch = STRING_ELT(value, 0);
        const char *ptr = Rf_translateCharUTF8(ch);
        duckdb_vector_assign_string_element_len(output->vector, row, ptr, (idx_t)strlen(ptr));
        return 1;
    }
    case RDUCKS_TYPE_BLOB:
        if (TYPEOF(value) != RAWSXP) {
            snprintf(err_msg, err_cap, "Rducks RC BLOB output is not a raw vector");
            return 0;
        }
        duckdb_vector_assign_string_element_len(output->vector, row, (const char *)RAW(value), (idx_t)XLENGTH(value));
        return 1;
    case RDUCKS_TYPE_DATE:
        ((duckdb_date *)output->data)[row].days = (int32_t)Rf_asReal(value);
        return 1;
    case RDUCKS_TYPE_TIME:
        ((duckdb_time *)output->data)[row].micros = (int64_t)llround(Rf_asReal(value) * 1000000.0);
        return 1;
    case RDUCKS_TYPE_TIMESTAMP:
        ((duckdb_timestamp *)output->data)[row].micros = (int64_t)llround(Rf_asReal(value) * 1000000.0);
        return 1;
    default:
        snprintf(err_msg, err_cap, "Rducks RC direct output unsupported type");
        return 0;
    }
}

static int rducks_rc_direct_scalar_execute(rducks_r_scalar_meta_t *meta, duckdb_data_chunk input, duckdb_vector output,
                                           char *err_msg, size_t err_cap) {
    idx_t n = duckdb_data_chunk_get_size(input);
    SEXP bundle = meta->fun;
    SEXP fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_FUN);
    SEXP return_type = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_RETURN_TYPE);
    SEXP check_return_fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_CHECK_RETURN);
    rducks_rc_direct_vector_view_t *inputs = NULL;
    rducks_rc_direct_vector_view_t output_view;

    if (meta->arity > 0) {
        inputs = (rducks_rc_direct_vector_view_t *)calloc(meta->arity, sizeof(rducks_rc_direct_vector_view_t));
        if (!inputs) {
            snprintf(err_msg, err_cap, "out of memory allocating Rducks RC direct input views");
            return 0;
        }
        for (size_t col = 0; col < meta->arity; col++) {
            rducks_rc_direct_input_view_init(&inputs[col], duckdb_data_chunk_get_vector(input, (idx_t)col));
        }
    }
    rducks_rc_direct_output_view_init(&output_view, output);

    for (idx_t row = 0; row < n; row++) {
        int has_null = 0;
        for (size_t col = 0; col < meta->arity; col++) {
            if (!rducks_rc_direct_view_valid_at(&inputs[col], row)) {
                has_null = 1;
                break;
            }
        }
        if (meta->null_handling == RDUCKS_NULL_DEFAULT && has_null) {
            rducks_rc_output_set_null(&output_view, row);
            continue;
        }

        SEXP args = PROTECT(Rf_allocList((int)meta->arity));
        SEXP node = args;
        for (size_t col = 0; col < meta->arity; col++) {
            SEXP arg = PROTECT(rducks_rc_direct_arg(meta->args[col], &inputs[col], row));
            SETCAR(node, arg);
            UNPROTECT(1);
            node = CDR(node);
        }

        int r_err = 0;
        SEXP value = PROTECT(rducks_rc_call_user(fun, args, &r_err));
        UNPROTECT(1); /* args */
        if (r_err) {
            UNPROTECT(1); /* value */
            if (meta->exception_handling == RDUCKS_EXCEPTION_RETURN_NULL) {
                rducks_rc_output_set_null(&output_view, row);
                continue;
            }
            snprintf(err_msg, err_cap, "Rducks RC R function error");
            free(inputs);
            return 0;
        }

        r_err = 0;
        SEXP checked = PROTECT(rducks_rc_check_return(check_return_fun, return_type, value, &r_err));
        UNPROTECT(1); /* value */
        if (r_err) {
            UNPROTECT(1); /* checked */
            snprintf(err_msg, err_cap, "Rducks RC return validation or marshal error");
            free(inputs);
            return 0;
        }
        if (!rducks_rc_write_direct_output(meta->return_desc, &output_view, row, checked, err_msg, err_cap)) {
            UNPROTECT(1); /* checked */
            free(inputs);
            return 0;
        }
        UNPROTECT(1); /* checked */
    }
    free(inputs);
    return 1;
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
    if (rducks_rc_direct_supported(meta)) {
        return rducks_rc_direct_scalar_execute(meta, input, output, err_msg, err_cap);
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
