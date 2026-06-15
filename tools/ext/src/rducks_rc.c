/* Included by ../rducks_extension.c.
 *
 * The direct evaluator is intentionally a recorded-main-R-thread
 * implementation today. The scalar path now has an explicit worker-safe borrowed
 * DuckDB-vector view snapshot phase followed by main-R-thread evaluation and
 * writeback. The vectorized path is split into named main-R-thread phases, but
 * still materializes R objects directly from borrowed DuckDB vectors.
 *
 * Do not treat current R/SEXP materialization or SEXP result writeback helpers as
 * worker-thread safe. A later async implementation must complete the remaining
 * split into:
 *   1. worker-safe owned DuckDB/vector input snapshots with no R API;
 *   2. main-R-thread evaluation and SEXP result handling;
 *   3. worker-safe DuckDB output writes from owned, non-SEXP result memory.
 */

#define RDUCKS_RC_BUNDLE_FUN 0
#define RDUCKS_RC_BUNDLE_ARG_TYPES 1
#define RDUCKS_RC_BUNDLE_RETURN_TYPE 2
#define RDUCKS_RC_BUNDLE_PREPARE_INPUTS 3
#define RDUCKS_RC_BUNDLE_CHECK_RETURN 4
#define RDUCKS_RC_BUNDLE_RESULT_ARRAY 5
#define RDUCKS_RC_BUNDLE_EVAL_ROWS 6
#define RDUCKS_RC_BUNDLE_SIZE 7

static int rducks_rc_bundle_valid(SEXP bundle) {
    return TYPEOF(bundle) == VECSXP && XLENGTH(bundle) >= RDUCKS_RC_BUNDLE_SIZE &&
           Rf_isFunction(VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_FUN)) &&
           Rf_isFunction(VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_PREPARE_INPUTS)) &&
           Rf_isFunction(VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_CHECK_RETURN)) &&
           Rf_isFunction(VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_RESULT_ARRAY)) &&
           Rf_isFunction(VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_EVAL_ROWS));
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

static int rducks_rc_has_known_scalar_class(SEXP values) {
    return Rf_inherits(values, "Date") || Rf_inherits(values, "POSIXct") ||
           Rf_inherits(values, "rducks_bigint") || Rf_inherits(values, "rducks_ubigint") ||
           Rf_inherits(values, "rducks_hugeint") || Rf_inherits(values, "rducks_uhugeint") ||
           Rf_inherits(values, "rducks_uuid") || Rf_inherits(values, "rducks_enum");
}

static void rducks_rc_copy_known_scalar_attrib(SEXP values, SEXP out) {
    SEXP klass;
    if (!rducks_rc_has_known_scalar_class(values)) return;
    klass = Rf_getAttrib(values, R_ClassSymbol);
    if (klass != R_NilValue) Rf_setAttrib(out, R_ClassSymbol, klass);
    if (Rf_inherits(values, "rducks_enum") || Rf_inherits(values, "factor")) {
        SEXP levels = Rf_getAttrib(values, R_LevelsSymbol);
        if (levels != R_NilValue) Rf_setAttrib(out, R_LevelsSymbol, levels);
    }
    if (Rf_inherits(values, "POSIXct")) {
        SEXP tzone = Rf_getAttrib(values, Rf_install("tzone"));
        if (tzone != R_NilValue) Rf_setAttrib(out, Rf_install("tzone"), tzone);
    }
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
        rducks_rc_copy_known_scalar_attrib(values, out);
        UNPROTECT(1);
        return out;
    case INTSXP:
        if (i < 0 || i >= XLENGTH(values)) { *ok = 0; return R_NilValue; }
        out = PROTECT(Rf_allocVector(INTSXP, 1));
        INTEGER(out)[0] = INTEGER(values)[i];
        rducks_rc_copy_known_scalar_attrib(values, out);
        UNPROTECT(1);
        return out;
    case REALSXP:
        if (i < 0 || i >= XLENGTH(values)) { *ok = 0; return R_NilValue; }
        out = PROTECT(Rf_allocVector(REALSXP, 1));
        REAL(out)[0] = REAL(values)[i];
        rducks_rc_copy_known_scalar_attrib(values, out);
        UNPROTECT(1);
        return out;
    case STRSXP:
        if (i < 0 || i >= XLENGTH(values)) { *ok = 0; return R_NilValue; }
        out = PROTECT(Rf_allocVector(STRSXP, 1));
        SET_STRING_ELT(out, 0, STRING_ELT(values, i));
        rducks_rc_copy_known_scalar_attrib(values, out);
        UNPROTECT(1);
        return out;
    case RAWSXP:
        if (i < 0 || i >= XLENGTH(values)) { *ok = 0; return R_NilValue; }
        out = PROTECT(Rf_allocVector(RAWSXP, 1));
        RAW(out)[0] = RAW(values)[i];
        rducks_rc_copy_known_scalar_attrib(values, out);
        UNPROTECT(1);
        return out;
    default:
        return rducks_rc_subset_with_bracket(values, row, ok);
    }
}

static SEXP rducks_rc_call_user(SEXP fun, SEXP args, int *r_err) {
    PROTECT(fun);
    PROTECT(args);
    SEXP call = PROTECT(Rf_lcons(fun, args));
    SEXP value = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, r_err));
    UNPROTECT(4);
    return value;
}

static SEXP rducks_rc_check_return(SEXP check_return_fun, SEXP return_type, SEXP value, int *r_err) {
    PROTECT(check_return_fun);
    PROTECT(return_type);
    PROTECT(value);
    SEXP call = PROTECT(Rf_lang3(check_return_fun, return_type, value));
    SEXP checked = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, r_err));
    UNPROTECT(5);
    return checked;
}

static SEXP rducks_rc_null_handling_sexp(rducks_null_handling_t null_handling) {
    return Rf_mkString(null_handling == RDUCKS_NULL_SPECIAL ? "special" : "default");
}

static SEXP rducks_rc_exception_handling_sexp(rducks_exception_handling_t exception_handling) {
    return Rf_mkString(exception_handling == RDUCKS_EXCEPTION_RETURN_NULL ? "return_null" : "rethrow");
}

static SEXP rducks_rc_call_vectorized_eval(SEXP eval_rows_fun, SEXP fun, SEXP arg_types, SEXP return_type,
                                           SEXP prepared, SEXP null_handling, SEXP exception_handling,
                                           int *r_err) {
    SEXP args = PROTECT(Rf_allocList(6));
    SEXP node = args;
    SETCAR(node, fun);
    node = CDR(node);
    SETCAR(node, arg_types);
    node = CDR(node);
    SETCAR(node, return_type);
    node = CDR(node);
    SETCAR(node, prepared);
    node = CDR(node);
    SETCAR(node, null_handling);
    node = CDR(node);
    SETCAR(node, exception_handling);
    SEXP call = PROTECT(Rf_lcons(eval_rows_fun, args));
    SEXP value = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, r_err));
    UNPROTECT(3);
    return value;
}


static int rducks_rc_direct_enum_supported(const rducks_type_desc_t *desc) {
    return desc && desc->kind == RDUCKS_KIND_ENUM &&
           (desc->enum_internal_type == DUCKDB_TYPE_UTINYINT ||
            desc->enum_internal_type == DUCKDB_TYPE_USMALLINT ||
            desc->enum_internal_type == DUCKDB_TYPE_UINTEGER);
}

static int rducks_rc_direct_type_supported(const rducks_type_desc_t *desc);

static int rducks_rc_direct_sequence_child_supported(const rducks_type_desc_t *desc) {
    if (!desc) return 0;
    if (desc->kind == RDUCKS_KIND_LIST || desc->kind == RDUCKS_KIND_ARRAY ||
        desc->kind == RDUCKS_KIND_STRUCT || desc->kind == RDUCKS_KIND_MAP ||
        desc->kind == RDUCKS_KIND_UNION) {
        return rducks_rc_direct_type_supported(desc);
    }
    if (desc->kind == RDUCKS_KIND_DECIMAL) return 1;
    if (rducks_rc_direct_enum_supported(desc)) return 1;
    if (desc->kind != RDUCKS_KIND_SCALAR) return 0;
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
    case RDUCKS_TYPE_DATE:
    case RDUCKS_TYPE_TIME:
    case RDUCKS_TYPE_TIMESTAMP:
        return 1;
    default:
        return 0;
    }
}

static int rducks_rc_direct_type_supported(const rducks_type_desc_t *desc) {
    if (!desc) return 0;
    if (desc->kind == RDUCKS_KIND_DECIMAL) return 1;
    if (desc->kind == RDUCKS_KIND_ENUM) return rducks_rc_direct_enum_supported(desc);
    if (desc->kind == RDUCKS_KIND_LIST || desc->kind == RDUCKS_KIND_ARRAY) {
        return rducks_rc_direct_sequence_child_supported(desc->child);
    }
    if (desc->kind == RDUCKS_KIND_STRUCT) {
        if (desc->field_count == 0) return 0;
        for (size_t i = 0; i < desc->field_count; i++) {
            if (!rducks_rc_direct_type_supported(desc->field_types[i])) return 0;
        }
        return 1;
    }
    if (desc->kind == RDUCKS_KIND_MAP) {
        return rducks_rc_direct_sequence_child_supported(desc->key) &&
               rducks_rc_direct_sequence_child_supported(desc->value);
    }
    if (desc->kind == RDUCKS_KIND_UNION) {
        if (desc->field_count == 0 || desc->field_count > 255U) return 0;
        for (size_t i = 0; i < desc->field_count; i++) {
            if (!rducks_rc_direct_type_supported(desc->field_types[i])) return 0;
        }
        return 1;
    }
    if (desc->kind != RDUCKS_KIND_SCALAR) return 0;
    switch (desc->scalar) {
    case RDUCKS_TYPE_BOOL:
    case RDUCKS_TYPE_I8:
    case RDUCKS_TYPE_U8:
    case RDUCKS_TYPE_I16:
    case RDUCKS_TYPE_U16:
    case RDUCKS_TYPE_I32:
    case RDUCKS_TYPE_U32:
    case RDUCKS_TYPE_I64:
    case RDUCKS_TYPE_U64:
    case RDUCKS_TYPE_F32:
    case RDUCKS_TYPE_F64:
    case RDUCKS_TYPE_VARCHAR:
    case RDUCKS_TYPE_BLOB:
    case RDUCKS_TYPE_GEOMETRY:
    case RDUCKS_TYPE_DATE:
    case RDUCKS_TYPE_TIME:
    case RDUCKS_TYPE_TIMESTAMP:
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

static void rducks_rc_direct_view_init(rducks_rc_direct_vector_view_t *view, duckdb_vector vector) {
    view->vector = vector;
    view->data = duckdb_vector_get_data(vector);
    view->validity = duckdb_vector_get_validity(vector);
}

typedef struct rducks_rc_direct_scalar_frame {
    idx_t n;
    size_t arity;
    rducks_rc_direct_vector_view_t *inputs;
    rducks_rc_direct_vector_view_t output;
} rducks_rc_direct_scalar_frame_t;

static void rducks_rc_direct_scalar_frame_init(rducks_rc_direct_scalar_frame_t *frame) {
    if (!frame) return;
    memset(frame, 0, sizeof(*frame));
}

static void rducks_rc_direct_scalar_frame_cleanup(rducks_rc_direct_scalar_frame_t *frame) {
    if (!frame) return;
    free(frame->inputs);
    frame->inputs = NULL;
    frame->arity = 0U;
    frame->n = 0;
}

static int rducks_rc_direct_input_snapshot_supported(rducks_r_scalar_meta_t *meta) {
    if (!meta || (meta->eval_mode != RDUCKS_EVAL_RC && meta->eval_mode != RDUCKS_EVAL_RCV)) return 0;
    for (size_t i = 0; i < meta->arity; i++) {
        if (!rducks_rc_direct_type_supported(meta->args[i])) return 0;
    }
    return 1;
}

/* Worker-safe phase: copy queued direct inputs into an owned DuckDB data
 * chunk before handing the request to the recorded main R thread. The main
 * thread may then materialize R arguments from snapshot-owned vector storage
 * instead of borrowing the waiting DuckDB worker callback frame. The output
 * vector is still owned by the active callback unless the owned-result payload
 * path is also selected.
 */
static int rducks_rc_direct_input_snapshot_chunk(rducks_r_scalar_meta_t *meta,
                                                 duckdb_data_chunk input,
                                                 duckdb_data_chunk *snapshot_out,
                                                 char *err_msg, size_t err_cap) {
    duckdb_logical_type *types = NULL;
    duckdb_data_chunk snapshot = NULL;
    duckdb_selection_vector sel = NULL;
    idx_t n;
    int ok = 0;

    if (snapshot_out) *snapshot_out = NULL;
    if (!meta || !input || !snapshot_out) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC input snapshot is missing state");
        return 0;
    }
    if (!rducks_rc_direct_input_snapshot_supported(meta)) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC input snapshot is not supported for this UDF signature");
        return 0;
    }
    if (meta->arity == 0U) return 1;
    if (meta->arity > (SIZE_MAX / sizeof(*types))) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC input snapshot arity is too large");
        return 0;
    }

    n = duckdb_data_chunk_get_size(input);
    if (n > (idx_t)UINT32_MAX) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC input snapshot chunk is too large");
        return 0;
    }

    types = (duckdb_logical_type *)rducks_calloc_array(meta->arity, sizeof(*types));
    if (!types) {
        rducks_format_error_message(err_msg, err_cap, "failed to allocate Rducks RC input snapshot types");
        return 0;
    }
    for (size_t col = 0; col < meta->arity; col++) {
        types[col] = rducks_create_logical_type_for_desc(meta->args[col]);
        if (!types[col]) {
            rducks_format_error_message(err_msg, err_cap, "failed to allocate Rducks RC input snapshot logical type");
            goto cleanup;
        }
    }

    snapshot = duckdb_create_data_chunk(types, (idx_t)meta->arity);
    if (!snapshot) {
        rducks_format_error_message(err_msg, err_cap, "failed to allocate Rducks RC input snapshot data chunk");
        goto cleanup;
    }
    duckdb_data_chunk_set_size(snapshot, n);

    if (n > 0) {
        sel_t *sel_data;
        sel = duckdb_create_selection_vector(n);
        if (!sel) {
            rducks_format_error_message(err_msg, err_cap, "failed to allocate Rducks RC input snapshot selection vector");
            goto cleanup;
        }
        sel_data = duckdb_selection_vector_get_data_ptr(sel);
        if (!sel_data) {
            rducks_format_error_message(err_msg, err_cap, "failed to access Rducks RC input snapshot selection vector");
            goto cleanup;
        }
        for (idx_t row = 0; row < n; row++) sel_data[row] = (sel_t)row;

        for (size_t col = 0; col < meta->arity; col++) {
            duckdb_vector src = duckdb_data_chunk_get_vector(input, (idx_t)col);
            duckdb_vector dst = duckdb_data_chunk_get_vector(snapshot, (idx_t)col);
            if (!src || !dst) {
                rducks_format_error_message(err_msg, err_cap, "failed to access Rducks RC input snapshot vector");
                goto cleanup;
            }
            duckdb_vector_copy_sel(src, dst, sel, n, 0, 0);
        }
        duckdb_data_chunk_set_size(snapshot, n);
    }

    *snapshot_out = snapshot;
    snapshot = NULL;
    ok = 1;

cleanup:
    if (sel) duckdb_destroy_selection_vector(sel);
    if (snapshot) duckdb_destroy_data_chunk(&snapshot);
    if (types) {
        for (size_t col = 0; col < meta->arity; col++) {
            if (types[col]) duckdb_destroy_logical_type(&types[col]);
        }
        free(types);
    }
    return ok;
}

/* Worker-safe phase: capture DuckDB vector views needed by direct scalar
 * execution. This phase must not allocate or touch SEXP objects and must not
 * call any R API. The views remain borrowed from the active DuckDB callback
 * frame, so the callback must stay blocked until later phases finish.
 */
static int rducks_rc_direct_scalar_snapshot_input_views(rducks_r_scalar_meta_t *meta,
                                                        duckdb_data_chunk input,
                                                        rducks_rc_direct_scalar_frame_t *frame,
                                                        char *err_msg, size_t err_cap) {
    if (!meta || !frame) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC scalar snapshot is missing state");
        return 0;
    }
    rducks_rc_direct_scalar_frame_init(frame);
    frame->n = duckdb_data_chunk_get_size(input);
    frame->arity = meta->arity;
    if (meta->arity > 0U) {
        frame->inputs = (rducks_rc_direct_vector_view_t *)rducks_calloc_array(meta->arity, sizeof(*frame->inputs));
        if (!frame->inputs) {
            rducks_format_error_message(err_msg, err_cap, "failed to allocate Rducks RC scalar input views");
            return 0;
        }
        for (size_t col = 0; col < meta->arity; col++) {
            rducks_rc_direct_view_init(&frame->inputs[col], duckdb_data_chunk_get_vector(input, (idx_t)col));
        }
    }
    return 1;
}

static int rducks_rc_direct_scalar_snapshot_views(rducks_r_scalar_meta_t *meta,
                                                  duckdb_data_chunk input,
                                                  duckdb_vector output,
                                                  rducks_rc_direct_scalar_frame_t *frame,
                                                  char *err_msg, size_t err_cap) {
    if (!rducks_rc_direct_scalar_snapshot_input_views(meta, input, frame, err_msg, err_cap)) {
        return 0;
    }
    rducks_rc_direct_view_init(&frame->output, output);
    return 1;
}

static int rducks_rc_direct_view_valid_at(const rducks_rc_direct_vector_view_t *view, idx_t row) {
    if (!view->validity) return 1;
    return duckdb_validity_row_is_valid(view->validity, row) ? 1 : 0;
}

static int rducks_rc_idx_add(idx_t a, idx_t b, idx_t *out) {
    if (UINT64_MAX - a < b) return 0;
    *out = a + b;
    return 1;
}

static int rducks_rc_idx_mul(idx_t a, idx_t b, idx_t *out) {
    if (b != 0 && a > UINT64_MAX / b) return 0;
    *out = a * b;
    return 1;
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


#define RDUCKS_RC_DEC_BASE 1000000000U
#define RDUCKS_RC_DEC_BASE_DIGITS 9U

static void rducks_rc_u64_to_le_bytes(uint64_t value, uint8_t *bytes) {
    for (int i = 0; i < 8; i++) bytes[i] = (uint8_t)((value >> (8 * i)) & 0xffU);
}

static uint64_t rducks_rc_le_bytes_to_u64(const uint8_t *bytes) {
    uint64_t value = 0;
    for (int i = 7; i >= 0; i--) value = (value << 8) | (uint64_t)bytes[i];
    return value;
}

static int rducks_rc_limbs_mul_add(uint32_t *limbs, size_t *nlimbs, size_t cap,
                                    uint32_t multiplier, uint32_t addend) {
    uint64_t carry = addend;
    for (size_t i = 0; i < *nlimbs; i++) {
        uint64_t value = (uint64_t)limbs[i] * (uint64_t)multiplier + carry;
        limbs[i] = (uint32_t)(value % RDUCKS_RC_DEC_BASE);
        carry = value / RDUCKS_RC_DEC_BASE;
    }
    while (carry) {
        if (*nlimbs >= cap) return 0;
        limbs[*nlimbs] = (uint32_t)(carry % RDUCKS_RC_DEC_BASE);
        carry /= RDUCKS_RC_DEC_BASE;
        (*nlimbs)++;
    }
    return 1;
}

static size_t rducks_rc_unsigned_le_bytes_to_decimal_buf(const uint8_t *bytes, size_t n, char *out, size_t out_cap) {
    if (n == 0) {
        if (out_cap < 2) return 0;
        out[0] = '0';
        out[1] = '\0';
        return 1;
    }
    size_t cap = n + 1U;
    uint32_t *limbs = (uint32_t *)R_alloc(cap, sizeof(uint32_t));
    memset(limbs, 0, cap * sizeof(uint32_t));
    size_t nlimbs = 1U;
    for (size_t i = n; i > 0; i--) {
        if (!rducks_rc_limbs_mul_add(limbs, &nlimbs, cap, 256U, (uint32_t)bytes[i - 1U])) return 0;
    }
    while (nlimbs > 1U && limbs[nlimbs - 1U] == 0U) nlimbs--;
    if (nlimbs == 1U && limbs[0] == 0U) {
        if (out_cap < 2) return 0;
        out[0] = '0';
        out[1] = '\0';
        return 1;
    }
    size_t pos = 0;
    pos += (size_t)snprintf(out + pos, out_cap - pos, "%u", limbs[nlimbs - 1U]);
    for (size_t j = nlimbs - 1U; j > 0; j--) {
        pos += (size_t)snprintf(out + pos, out_cap - pos, "%09u", limbs[j - 1U]);
    }
    return pos;
}

static size_t rducks_rc_int_le_bytes_to_decimal_buf(const uint8_t *bytes, size_t n, int signed_value, char *out, size_t out_cap) {
    uint8_t *tmp = (uint8_t *)R_alloc(n ? n : 1U, sizeof(uint8_t));
    if (n) memcpy(tmp, bytes, n);
    int neg = signed_value && n > 0 && tmp[n - 1U] >= 128U;
    if (neg) {
        for (size_t i = 0; i < n; i++) tmp[i] = (uint8_t)(255U - tmp[i]);
        int carry = 1;
        for (size_t i = 0; i < n; i++) {
            int value = (int)tmp[i] + carry;
            tmp[i] = (uint8_t)(value & 0xff);
            carry = value >> 8;
            if (!carry) break;
        }
    }
    size_t pos = 0;
    if (neg) out[pos++] = '-';
    pos += rducks_rc_unsigned_le_bytes_to_decimal_buf(tmp, n, out + pos, out_cap - pos);
    out[pos] = '\0';
    return pos;
}

static const char *rducks_rc_trim_string(SEXP ch, size_t *len) {
    const char *start = CHAR(ch);
    const char *end = start + strlen(start);
    while (start < end && isspace((unsigned char)*start)) start++;
    while (end > start && isspace((unsigned char)*(end - 1))) end--;
    *len = (size_t)(end - start);
    return start;
}

static const char *rducks_rc_skip_zeros(const char *x, size_t *len) {
    while (*len > 0 && *x == '0') {
        x++;
        (*len)--;
    }
    return x;
}

static int rducks_rc_decimal_abs_to_unsigned_bytes(const char *digits, size_t len, int width, uint8_t *out,
                                                   char *err_msg, size_t err_cap) {
    memset(out, 0, (size_t)width);
    digits = rducks_rc_skip_zeros(digits, &len);
    if (len == 0) return 1;
    unsigned char *work = (unsigned char *)R_alloc(len, sizeof(unsigned char));
    for (size_t i = 0; i < len; i++) {
        if (digits[i] < '0' || digits[i] > '9') {
            rducks_format_error_message(err_msg, err_cap, "expected a decimal integer string");
            return 0;
        }
        work[i] = (unsigned char)(digits[i] - '0');
    }
    size_t ndigits = len;
    int byte_pos = 0;
    while (ndigits > 0) {
        if (byte_pos >= width) {
            rducks_format_error_message(err_msg, err_cap, "integer value does not fit in DuckDB storage");
            return 0;
        }
        int carry = 0;
        size_t write = 0;
        int started = 0;
        for (size_t i = 0; i < ndigits; i++) {
            int value = carry * 10 + work[i];
            int q = value / 256;
            carry = value % 256;
            if (q != 0 || started) {
                work[write++] = (unsigned char)q;
                started = 1;
            }
        }
        out[byte_pos++] = (uint8_t)carry;
        ndigits = write;
    }
    return 1;
}

static int rducks_rc_decimal_string_to_le_bytes(const char *s, size_t len, int width, int signed_value, uint8_t *out,
                                                char *err_msg, size_t err_cap) {
    int neg = 0;
    if (len > 0 && s[0] == '+') {
        s++;
        len--;
    } else if (len > 0 && s[0] == '-') {
        neg = 1;
        s++;
        len--;
    }
    if (neg && !signed_value) {
        rducks_format_error_message(err_msg, err_cap, "unsigned integer value is negative");
        return 0;
    }
    if (!rducks_rc_decimal_abs_to_unsigned_bytes(s, len, width, out, err_msg, err_cap)) return 0;
    if (signed_value && width > 0) {
        if (!neg) {
            if (out[width - 1] >= 128U) {
                rducks_format_error_message(err_msg, err_cap, "signed integer value does not fit in DuckDB storage");
                return 0;
            }
        } else {
            int overflow = out[width - 1] > 128U;
            if (out[width - 1] == 128U) {
                for (int i = 0; i < width - 1; i++) {
                    if (out[i] != 0U) {
                        overflow = 1;
                        break;
                    }
                }
            }
            if (overflow) {
                rducks_format_error_message(err_msg, err_cap, "signed integer value does not fit in DuckDB storage");
                return 0;
            }
        }
    }
    if (neg) {
        for (int i = 0; i < width; i++) out[i] = (uint8_t)(255U - out[i]);
        int carry = 1;
        for (int i = 0; i < width; i++) {
            int value = (int)out[i] + carry;
            out[i] = (uint8_t)(value & 0xff);
            carry = value >> 8;
            if (!carry) break;
        }
    }
    return 1;
}

static int rducks_rc_decimal_string_sexp_to_le_bytes(SEXP value, int width, int signed_value, uint8_t *out,
                                                     char *err_msg, size_t err_cap) {
    if (TYPEOF(value) != STRSXP || XLENGTH(value) < 1 || STRING_ELT(value, 0) == NA_STRING) {
        rducks_format_error_message(err_msg, err_cap, "expected a non-missing decimal integer string");
        return 0;
    }
    size_t len = 0;
    const char *s = rducks_rc_trim_string(STRING_ELT(value, 0), &len);
    return rducks_rc_decimal_string_to_le_bytes(s, len, width, signed_value, out, err_msg, err_cap);
}

static SEXP rducks_rc_make_classed_string_len(const char *value, size_t len, const char *class_name) {
    SEXP out = PROTECT(Rf_allocVector(STRSXP, 1));
    SEXP cls = PROTECT(Rf_allocVector(STRSXP, 2));
    SET_STRING_ELT(out, 0, Rf_mkCharLenCE(value, (int)len, CE_UTF8));
    SET_STRING_ELT(cls, 0, Rf_mkChar(class_name));
    SET_STRING_ELT(cls, 1, Rf_mkChar("character"));
    Rf_setAttrib(out, R_ClassSymbol, cls);
    UNPROTECT(2);
    return out;
}

static SEXP rducks_rc_make_integer_object_from_le_bytes(const uint8_t *bytes, size_t width, int signed_value,
                                                        const char *class_name) {
    char buf[160];
    size_t len = rducks_rc_int_le_bytes_to_decimal_buf(bytes, width, signed_value, buf, sizeof(buf));
    return rducks_rc_make_classed_string_len(buf, len, class_name);
}

static int rducks_rc_decimal_storage_string_to_le_bytes(SEXP value, int width, int scale, uint8_t *out,
                                                        char *err_msg, size_t err_cap) {
    if (TYPEOF(value) != VECSXP || XLENGTH(value) < 1) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC DECIMAL output is not a rducks_decimal object");
        return 0;
    }
    SEXP values = VECTOR_ELT(value, 0);
    if (TYPEOF(values) != STRSXP || XLENGTH(values) < 1 || STRING_ELT(values, 0) == NA_STRING) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC DECIMAL output is missing");
        return 0;
    }
    size_t len = 0;
    const char *s = rducks_rc_trim_string(STRING_ELT(values, 0), &len);
    int neg = 0;
    if (len > 0 && s[0] == '+') {
        s++;
        len--;
    } else if (len > 0 && s[0] == '-') {
        neg = 1;
        s++;
        len--;
    }
    char *digits = (char *)R_alloc(len + 2U, sizeof(char));
    size_t pos = 0;
    if (neg) digits[pos++] = '-';
    for (size_t i = 0; i < len; i++) {
        if (s[i] == '.') continue;
        if (s[i] < '0' || s[i] > '9') {
            rducks_format_error_message(err_msg, err_cap, "DECIMAL values must be fixed-point decimal strings");
            return 0;
        }
        digits[pos++] = s[i];
    }
    digits[pos] = '\0';
    (void)scale;
    return rducks_rc_decimal_string_to_le_bytes(digits, pos, width, 1, out, err_msg, err_cap);
}

static void rducks_rc_le_bytes_to_hugeint(const uint8_t *bytes, duckdb_hugeint *out) {
    out->lower = rducks_rc_le_bytes_to_u64(bytes);
    uint64_t upper_u = rducks_rc_le_bytes_to_u64(bytes + 8);
    memcpy(&out->upper, &upper_u, sizeof(out->upper));
}

static void rducks_rc_le_bytes_to_uhugeint(const uint8_t *bytes, duckdb_uhugeint *out) {
    out->lower = rducks_rc_le_bytes_to_u64(bytes);
    out->upper = rducks_rc_le_bytes_to_u64(bytes + 8);
}

static SEXP rducks_rc_make_decimal_object_from_storage_bytes(const uint8_t *bytes, size_t storage_width,
                                                             int width, int scale) {
    char integer_buf[160];
    size_t integer_len = rducks_rc_int_le_bytes_to_decimal_buf(bytes, storage_width, 1, integer_buf, sizeof(integer_buf));
    int neg = integer_len > 0 && integer_buf[0] == '-';
    const char *digits = integer_buf + (neg ? 1 : 0);
    size_t digit_len = integer_len - (neg ? 1U : 0U);
    digits = rducks_rc_skip_zeros(digits, &digit_len);
    if (digit_len == 0) {
        digits = "0";
        digit_len = 1;
        neg = 0;
    }
    size_t padded_len = scale > 0 && digit_len <= (size_t)scale ? (size_t)scale + 1U : digit_len;
    char *padded = (char *)R_alloc(padded_len + 1U, sizeof(char));
    size_t pad = padded_len - digit_len;
    memset(padded, '0', pad);
    memcpy(padded + pad, digits, digit_len);
    padded[padded_len] = '\0';
    size_t whole_len = scale > 0 ? padded_len - (size_t)scale : padded_len;
    const char *whole = rducks_rc_skip_zeros(padded, &whole_len);
    if (whole_len == 0) {
        whole = "0";
        whole_len = 1;
    }
    size_t out_len = (neg ? 1U : 0U) + whole_len + (scale > 0 ? 1U + (size_t)scale : 0U);
    char *buf = (char *)R_alloc(out_len + 1U, sizeof(char));
    size_t pos = 0;
    if (neg) buf[pos++] = '-';
    memcpy(buf + pos, whole, whole_len);
    pos += whole_len;
    if (scale > 0) {
        buf[pos++] = '.';
        memcpy(buf + pos, padded + padded_len - (size_t)scale, (size_t)scale);
        pos += (size_t)scale;
    }
    buf[pos] = '\0';

    SEXP out = PROTECT(Rf_allocVector(VECSXP, 3));
    SEXP value = PROTECT(Rf_allocVector(STRSXP, 1));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 3));
    SEXP cls = PROTECT(Rf_mkString("rducks_decimal"));
    SET_STRING_ELT(value, 0, Rf_mkCharLenCE(buf, (int)out_len, CE_UTF8));
    SET_VECTOR_ELT(out, 0, value);
    SET_VECTOR_ELT(out, 1, Rf_ScalarInteger(width));
    SET_VECTOR_ELT(out, 2, Rf_ScalarInteger(scale));
    SET_STRING_ELT(names, 0, Rf_mkChar("value"));
    SET_STRING_ELT(names, 1, Rf_mkChar("width"));
    SET_STRING_ELT(names, 2, Rf_mkChar("scale"));
    Rf_setAttrib(out, R_NamesSymbol, names);
    Rf_setAttrib(out, R_ClassSymbol, cls);
    UNPROTECT(4);
    return out;
}

static int rducks_rc_decimal_storage_width(const rducks_type_desc_t *desc) {
    if (desc->decimal_width <= 4) return 2;
    if (desc->decimal_width <= 9) return 4;
    if (desc->decimal_width <= 18) return 8;
    return 16;
}

static SEXP rducks_rc_make_uuid_from_hugeint(duckdb_hugeint value) {
    static const char hex[] = "0123456789abcdef";
    uint64_t upper = ((uint64_t)value.upper) ^ (UINT64_C(1) << 63);
    uint64_t lower = value.lower;
    uint8_t bytes[16];
    for (int i = 0; i < 8; i++) bytes[i] = (uint8_t)((upper >> (56 - 8 * i)) & 0xffU);
    for (int i = 0; i < 8; i++) bytes[8 + i] = (uint8_t)((lower >> (56 - 8 * i)) & 0xffU);
    char buf[37];
    int pos = 0;
    for (int i = 0; i < 16; i++) {
        if (i == 4 || i == 6 || i == 8 || i == 10) buf[pos++] = '-';
        buf[pos++] = hex[(bytes[i] >> 4) & 0x0f];
        buf[pos++] = hex[bytes[i] & 0x0f];
    }
    buf[pos] = '\0';
    return rducks_rc_make_classed_string_len(buf, 36, "rducks_uuid");
}

static int rducks_rc_parse_uuid_string(SEXP value, duckdb_hugeint *out, char *err_msg, size_t err_cap) {
    if (TYPEOF(value) != STRSXP || XLENGTH(value) < 1 || STRING_ELT(value, 0) == NA_STRING) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC UUID output is not a non-missing UUID string");
        return 0;
    }
    const char *s = CHAR(STRING_ELT(value, 0));
    uint64_t upper = 0, lower = 0;
    int count = 0;
    for (size_t i = 0; s[i] != '\0'; i++) {
        unsigned char ch = (unsigned char)s[i];
        if (ch == '-') continue;
        int v;
        if (ch >= '0' && ch <= '9') v = ch - '0';
        else if (ch >= 'a' && ch <= 'f') v = 10 + ch - 'a';
        else if (ch >= 'A' && ch <= 'F') v = 10 + ch - 'A';
        else {
            rducks_format_error_message(err_msg, err_cap, "invalid UUID value");
            return 0;
        }
        if (count >= 32) {
            rducks_format_error_message(err_msg, err_cap, "invalid UUID value");
            return 0;
        }
        if (count < 16) upper = (upper << 4) | (uint64_t)v;
        else lower = (lower << 4) | (uint64_t)v;
        count++;
    }
    if (count != 32) {
        rducks_format_error_message(err_msg, err_cap, "invalid UUID value");
        return 0;
    }
    upper ^= (UINT64_C(1) << 63);
    out->lower = lower;
    memcpy(&out->upper, &upper, sizeof(out->upper));
    return 1;
}

static SEXP rducks_rc_make_interval_object(duckdb_interval value) {
    char micros_buf[64];
    int micros_len = snprintf(micros_buf, sizeof(micros_buf), "%lld", (long long)value.micros);
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 3));
    SEXP micros = PROTECT(Rf_allocVector(STRSXP, 1));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 3));
    SEXP cls = PROTECT(Rf_mkString("rducks_interval"));
    SET_VECTOR_ELT(out, 0, Rf_ScalarInteger(value.months));
    SET_VECTOR_ELT(out, 1, Rf_ScalarInteger(value.days));
    SET_STRING_ELT(micros, 0, Rf_mkCharLenCE(micros_buf, micros_len, CE_UTF8));
    SET_VECTOR_ELT(out, 2, micros);
    SET_STRING_ELT(names, 0, Rf_mkChar("months"));
    SET_STRING_ELT(names, 1, Rf_mkChar("days"));
    SET_STRING_ELT(names, 2, Rf_mkChar("micros"));
    Rf_setAttrib(out, R_NamesSymbol, names);
    Rf_setAttrib(out, R_ClassSymbol, cls);
    UNPROTECT(4);
    return out;
}

static int rducks_rc_interval_from_object(SEXP value, duckdb_interval *out, char *err_msg, size_t err_cap) {
    if (TYPEOF(value) != VECSXP || XLENGTH(value) < 3) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC INTERVAL output is not a rducks_interval object");
        return 0;
    }
    SEXP months = VECTOR_ELT(value, 0);
    SEXP days = VECTOR_ELT(value, 1);
    SEXP micros = VECTOR_ELT(value, 2);
    out->months = (int32_t)Rf_asInteger(months);
    out->days = (int32_t)Rf_asInteger(days);
    if (out->months == NA_INTEGER || out->days == NA_INTEGER) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC INTERVAL output is missing");
        return 0;
    }
    uint8_t bytes[8];
    if (!rducks_rc_decimal_string_sexp_to_le_bytes(micros, 8, 1, bytes, err_msg, err_cap)) return 0;
    uint64_t u = rducks_rc_le_bytes_to_u64(bytes);
    memcpy(&out->micros, &u, sizeof(out->micros));
    return 1;
}

static SEXP rducks_rc_make_bits_from_payload(const char *payload, uint32_t len) {
    if (len < 2) return R_NilValue;
    int padding = (unsigned char)payload[0];
    if (padding < 0 || padding > 7) return R_NilValue;
    int bit_length = (int)((len - 1U) * 8U) - padding;
    if (bit_length <= 0) return R_NilValue;
    R_xlen_t nbytes = (bit_length + 7) / 8;
    SEXP data = PROTECT(Rf_allocVector(RAWSXP, nbytes));
    memset(RAW(data), 0, (size_t)nbytes);
    for (int i = 0; i < bit_length; i++) {
        int storage_bit = padding + i;
        int src_byte = 1 + storage_bit / 8;
        int src_bit = storage_bit % 8;
        int value = (((const unsigned char *)payload)[src_byte] >> (7 - src_bit)) & 1U;
        if (value) {
            int dst_byte = i / 8;
            int dst_bit = i % 8;
            RAW(data)[dst_byte] = (Rbyte)(RAW(data)[dst_byte] | (Rbyte)(1U << (7 - dst_bit)));
        }
    }
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 2));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 2));
    SEXP cls = PROTECT(Rf_mkString("rducks_bits"));
    SET_VECTOR_ELT(out, 0, data);
    SET_VECTOR_ELT(out, 1, Rf_ScalarInteger(bit_length));
    SET_STRING_ELT(names, 0, Rf_mkChar("data"));
    SET_STRING_ELT(names, 1, Rf_mkChar("length"));
    Rf_setAttrib(out, R_NamesSymbol, names);
    Rf_setAttrib(out, R_ClassSymbol, cls);
    UNPROTECT(4);
    return out;
}

static int rducks_rc_payload_from_bits(SEXP value, char **payload_out, idx_t *len_out, char *err_msg, size_t err_cap) {
    if (TYPEOF(value) != VECSXP || XLENGTH(value) < 2) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC BIT output is not a rducks_bits object");
        return 0;
    }
    SEXP data = VECTOR_ELT(value, 0);
    int bit_length = Rf_asInteger(VECTOR_ELT(value, 1));
    if (TYPEOF(data) != RAWSXP || bit_length <= 0 || (R_xlen_t)bit_length > XLENGTH(data) * 8) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC BIT output has invalid storage");
        return 0;
    }
    int padding = (8 - (bit_length % 8)) % 8;
    idx_t len = (idx_t)(1 + (bit_length + 7) / 8);
    char *payload = (char *)R_alloc((size_t)len, sizeof(char));
    memset(payload, 0, (size_t)len);
    payload[0] = (char)padding;
    for (int bit_idx = 0; bit_idx < padding; bit_idx++) {
        payload[1] = (char)(((unsigned char)payload[1]) | (unsigned char)(1U << (7 - bit_idx)));
    }
    for (int i = 0; i < bit_length; i++) {
        int src_byte = i / 8;
        int src_bit = i % 8;
        int set = (RAW(data)[src_byte] >> (7 - src_bit)) & 1U;
        if (set) {
            int storage_bit = padding + i;
            int dst_byte = 1 + storage_bit / 8;
            int dst_bit = storage_bit % 8;
            payload[dst_byte] = (char)(((unsigned char)payload[dst_byte]) | (unsigned char)(1U << (7 - dst_bit)));
        }
    }
    *payload_out = payload;
    *len_out = len;
    return 1;
}

static int rducks_rc_enum_storage_width(const rducks_type_desc_t *desc) {
    if (!desc || desc->kind != RDUCKS_KIND_ENUM) return 0;
    switch (desc->enum_internal_type) {
    case DUCKDB_TYPE_UTINYINT:
        return 1;
    case DUCKDB_TYPE_USMALLINT:
        return 2;
    case DUCKDB_TYPE_UINTEGER:
        return 4;
    default:
        return 0;
    }
}

static uint32_t rducks_rc_enum_index_from_data(const rducks_type_desc_t *desc, const void *data, idx_t row) {
    switch (rducks_rc_enum_storage_width(desc)) {
    case 1:
        return ((const uint8_t *)data)[row];
    case 2:
        return ((const uint16_t *)data)[row];
    case 4:
        return ((const uint32_t *)data)[row];
    default:
        return UINT32_MAX;
    }
}

static int rducks_rc_enum_index_to_data(const rducks_type_desc_t *desc, void *data, idx_t row, uint32_t index) {
    switch (rducks_rc_enum_storage_width(desc)) {
    case 1:
        ((uint8_t *)data)[row] = (uint8_t)index;
        return 1;
    case 2:
        ((uint16_t *)data)[row] = (uint16_t)index;
        return 1;
    case 4:
        ((uint32_t *)data)[row] = index;
        return 1;
    default:
        return 0;
    }
}

static SEXP rducks_rc_make_enum(const rducks_type_desc_t *desc, int32_t index) {
    SEXP out = PROTECT(Rf_allocVector(INTSXP, 1));
    SEXP levels = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)desc->field_count));
    SEXP cls = PROTECT(Rf_allocVector(STRSXP, 2));
    if (index < 0 || (size_t)index >= desc->field_count) {
        INTEGER(out)[0] = NA_INTEGER;
    } else {
        INTEGER(out)[0] = index + 1;
    }
    for (size_t i = 0; i < desc->field_count; i++) {
        SET_STRING_ELT(levels, (R_xlen_t)i, Rf_mkChar(desc->field_names[i] ? desc->field_names[i] : ""));
    }
    SET_STRING_ELT(cls, 0, Rf_mkChar("rducks_enum"));
    SET_STRING_ELT(cls, 1, Rf_mkChar("factor"));
    Rf_setAttrib(out, R_LevelsSymbol, levels);
    Rf_setAttrib(out, R_ClassSymbol, cls);
    UNPROTECT(3);
    return out;
}

static int rducks_rc_enum_value_index(const rducks_type_desc_t *desc, SEXP value,
                                      uint32_t *index_out, char *err_msg, size_t err_cap) {
    SEXP ch = R_NilValue;
    const char *value_text;
    if (!desc || desc->kind != RDUCKS_KIND_ENUM || !index_out) {
        rducks_format_error_message(err_msg, err_cap, "Rducks enum metadata missing");
        return 0;
    }
    if (TYPEOF(value) == STRSXP && XLENGTH(value) > 0) {
        ch = STRING_ELT(value, 0);
    } else if (TYPEOF(value) == INTSXP && XLENGTH(value) > 0 && Rf_inherits(value, "factor")) {
        int idx = INTEGER(value)[0];
        SEXP levels = Rf_getAttrib(value, R_LevelsSymbol);
        if (idx == NA_INTEGER || TYPEOF(levels) != STRSXP || idx < 1 || idx > XLENGTH(levels)) {
            rducks_format_error_message(err_msg, err_cap, "Rducks enum return value is invalid");
            return 0;
        }
        if (XLENGTH(levels) == (R_xlen_t)desc->field_count) {
            int levels_match = 1;
            for (size_t i = 0; i < desc->field_count; i++) {
                SEXP level = STRING_ELT(levels, (R_xlen_t)i);
                const char *expected = desc->field_names[i] ? desc->field_names[i] : "";
                if (level == NA_STRING || strcmp(CHAR(level), expected) != 0) {
                    levels_match = 0;
                    break;
                }
            }
            if (levels_match) {
                *index_out = (uint32_t)(idx - 1);
                return 1;
            }
        }
        ch = STRING_ELT(levels, idx - 1);
    } else {
        rducks_format_error_message(err_msg, err_cap, "Rducks enum return value must be character or factor");
        return 0;
    }
    if (ch == NA_STRING) {
        rducks_format_error_message(err_msg, err_cap, "Rducks enum return value is NA");
        return 0;
    }
    value_text = CHAR(ch);
    {
        size_t index = 0;
        if (rducks_type_desc_find_field_index(desc, value_text, &index) && index <= (size_t)UINT32_MAX) {
            *index_out = (uint32_t)index;
            return 1;
        }
    }
    rducks_format_error_message(err_msg, err_cap, "Rducks enum return value is outside declared levels");
    return 0;
}

static SEXP rducks_rc_missing_arg(const rducks_type_desc_t *desc) {
    SEXP out;
    if (!desc) return R_NilValue;
    if (desc->kind == RDUCKS_KIND_ENUM) {
        return rducks_rc_make_enum(desc, -1);
    }
    if (desc->kind != RDUCKS_KIND_SCALAR) {
        return R_NilValue;
    }
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
    case RDUCKS_TYPE_GEOMETRY:
    default:
        return R_NilValue;
    }
}

static SEXP rducks_rc_direct_arg(const rducks_type_desc_t *desc, const rducks_rc_direct_vector_view_t *input, idx_t row);

static SEXP rducks_rc_named_field(SEXP value, const char *name, int *ok) {
    SEXP names;
    *ok = 1;
    if (TYPEOF(value) != VECSXP) {
        *ok = 0;
        return R_NilValue;
    }
    names = Rf_getAttrib(value, R_NamesSymbol);
    if (TYPEOF(names) != STRSXP || XLENGTH(names) != XLENGTH(value)) {
        *ok = 0;
        return R_NilValue;
    }
    for (R_xlen_t i = 0; i < XLENGTH(names); i++) {
        SEXP elt_name = STRING_ELT(names, i);
        if (elt_name != NA_STRING && name && strcmp(CHAR(elt_name), name) == 0) {
            return VECTOR_ELT(value, i);
        }
    }
    *ok = 0;
    return R_NilValue;
}

static int rducks_rc_any_duplicated(SEXP x, int *duplicated) {
    int r_err = 0;
    SEXP call = PROTECT(Rf_lang2(Rf_install("anyDuplicated"), x));
    SEXP value = PROTECT(R_tryEvalSilent(call, R_BaseEnv, &r_err));
    if (r_err || TYPEOF(value) != INTSXP || XLENGTH(value) < 1) {
        UNPROTECT(2);
        return 0;
    }
    *duplicated = INTEGER(value)[0] != 0;
    UNPROTECT(2);
    return 1;
}

static SEXP rducks_rc_make_union_value(const char *tag, SEXP payload) {
    PROTECT(payload);
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 2));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 2));
    SEXP cls = PROTECT(Rf_mkString("rducks_union"));
    SET_VECTOR_ELT(out, 0, Rf_mkString(tag ? tag : ""));
    SET_VECTOR_ELT(out, 1, payload);
    SET_STRING_ELT(names, 0, Rf_mkChar("tag"));
    SET_STRING_ELT(names, 1, Rf_mkChar("value"));
    Rf_setAttrib(out, R_NamesSymbol, names);
    Rf_setAttrib(out, R_ClassSymbol, cls);
    UNPROTECT(4);
    return out;
}

static SEXP rducks_rc_struct_field(SEXP value, const char *name, size_t index, int *ok) {
    SEXP names;
    int has_names = 0;
    *ok = 1;
    if (TYPEOF(value) != VECSXP) {
        *ok = 0;
        return R_NilValue;
    }
    names = Rf_getAttrib(value, R_NamesSymbol);
    if (TYPEOF(names) == STRSXP && XLENGTH(names) == XLENGTH(value)) {
        for (R_xlen_t i = 0; i < XLENGTH(names); i++) {
            SEXP elt_name = STRING_ELT(names, i);
            if (elt_name != NA_STRING && CHAR(elt_name)[0] != '\0') {
                has_names = 1;
                if (name && strcmp(CHAR(elt_name), name) == 0) {
                    return VECTOR_ELT(value, i);
                }
            }
        }
    }
    if (has_names) {
        *ok = 0;
        return R_NilValue;
    }
    if (index < (size_t)XLENGTH(value)) return VECTOR_ELT(value, (R_xlen_t)index);
    *ok = 0;
    return R_NilValue;
}

static SEXP rducks_rc_make_posixct_vector(R_xlen_t n) {
    SEXP out = PROTECT(Rf_allocVector(REALSXP, n));
    SEXP cls = PROTECT(Rf_allocVector(STRSXP, 2));
    SEXP tz = PROTECT(Rf_mkString("UTC"));
    SET_STRING_ELT(cls, 0, Rf_mkChar("POSIXct"));
    SET_STRING_ELT(cls, 1, Rf_mkChar("POSIXt"));
    Rf_setAttrib(out, R_ClassSymbol, cls);
    Rf_setAttrib(out, Rf_install("tzone"), tz);
    UNPROTECT(3);
    return out;
}

static SEXP rducks_rc_make_date_vector(R_xlen_t n) {
    SEXP out = PROTECT(Rf_allocVector(REALSXP, n));
    SEXP cls = PROTECT(Rf_mkString("Date"));
    Rf_setAttrib(out, R_ClassSymbol, cls);
    UNPROTECT(2);
    return out;
}

static SEXP rducks_rc_make_enum_vector(const rducks_type_desc_t *desc, R_xlen_t n) {
    SEXP out = PROTECT(Rf_allocVector(INTSXP, n));
    SEXP levels = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)desc->field_count));
    SEXP cls = PROTECT(Rf_allocVector(STRSXP, 2));
    for (size_t i = 0; i < desc->field_count; i++) {
        SET_STRING_ELT(levels, (R_xlen_t)i, Rf_mkChar(desc->field_names[i] ? desc->field_names[i] : ""));
    }
    SET_STRING_ELT(cls, 0, Rf_mkChar("rducks_enum"));
    SET_STRING_ELT(cls, 1, Rf_mkChar("factor"));
    Rf_setAttrib(out, R_LevelsSymbol, levels);
    Rf_setAttrib(out, R_ClassSymbol, cls);
    UNPROTECT(3);
    return out;
}

static SEXP rducks_rc_direct_sequence_arg(const rducks_type_desc_t *child_desc, duckdb_vector child_vector,
                                          idx_t start, idx_t len) {
    rducks_rc_direct_vector_view_t child_view;
    R_xlen_t n;
    SEXP out;
    idx_t end = 0;
    if (len > (idx_t)R_XLEN_T_MAX || !rducks_rc_idx_add(start, len, &end)) {
        Rf_error("Rducks LIST/ARRAY value is too large to materialize in R");
    }
    n = (R_xlen_t)len;
    rducks_rc_direct_view_init(&child_view, child_vector);
    if (child_desc->kind == RDUCKS_KIND_ENUM) {
        out = PROTECT(rducks_rc_make_enum_vector(child_desc, n));
        for (idx_t j = 0; j < len; j++) {
            if (!rducks_rc_direct_view_valid_at(&child_view, start + j)) {
                INTEGER(out)[(R_xlen_t)j] = NA_INTEGER;
            } else {
                uint32_t index = rducks_rc_enum_index_from_data(child_desc, child_view.data, start + j);
                INTEGER(out)[(R_xlen_t)j] = index < child_desc->field_count ? (int)index + 1 : NA_INTEGER;
            }
        }
        UNPROTECT(1);
        return out;
    }
    if (child_desc->kind == RDUCKS_KIND_SCALAR) {
        switch (child_desc->scalar) {
        case RDUCKS_TYPE_BOOL:
            out = PROTECT(Rf_allocVector(LGLSXP, n));
            for (idx_t j = 0; j < len; j++) LOGICAL(out)[(R_xlen_t)j] = rducks_rc_direct_view_valid_at(&child_view, start + j) ? (((bool *)child_view.data)[start + j] ? TRUE : FALSE) : NA_LOGICAL;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_I8:
            out = PROTECT(Rf_allocVector(INTSXP, n));
            for (idx_t j = 0; j < len; j++) INTEGER(out)[(R_xlen_t)j] = rducks_rc_direct_view_valid_at(&child_view, start + j) ? (int)((int8_t *)child_view.data)[start + j] : NA_INTEGER;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_U8:
            out = PROTECT(Rf_allocVector(INTSXP, n));
            for (idx_t j = 0; j < len; j++) INTEGER(out)[(R_xlen_t)j] = rducks_rc_direct_view_valid_at(&child_view, start + j) ? (int)((uint8_t *)child_view.data)[start + j] : NA_INTEGER;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_I16:
            out = PROTECT(Rf_allocVector(INTSXP, n));
            for (idx_t j = 0; j < len; j++) INTEGER(out)[(R_xlen_t)j] = rducks_rc_direct_view_valid_at(&child_view, start + j) ? (int)((int16_t *)child_view.data)[start + j] : NA_INTEGER;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_U16:
            out = PROTECT(Rf_allocVector(INTSXP, n));
            for (idx_t j = 0; j < len; j++) INTEGER(out)[(R_xlen_t)j] = rducks_rc_direct_view_valid_at(&child_view, start + j) ? (int)((uint16_t *)child_view.data)[start + j] : NA_INTEGER;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_I32:
            out = PROTECT(Rf_allocVector(INTSXP, n));
            for (idx_t j = 0; j < len; j++) INTEGER(out)[(R_xlen_t)j] = rducks_rc_direct_view_valid_at(&child_view, start + j) ? (int)((int32_t *)child_view.data)[start + j] : NA_INTEGER;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_U32:
            out = PROTECT(Rf_allocVector(REALSXP, n));
            for (idx_t j = 0; j < len; j++) REAL(out)[(R_xlen_t)j] = rducks_rc_direct_view_valid_at(&child_view, start + j) ? (double)((uint32_t *)child_view.data)[start + j] : NA_REAL;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_F32:
            out = PROTECT(Rf_allocVector(REALSXP, n));
            for (idx_t j = 0; j < len; j++) REAL(out)[(R_xlen_t)j] = rducks_rc_direct_view_valid_at(&child_view, start + j) ? (double)((float *)child_view.data)[start + j] : NA_REAL;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_F64:
        case RDUCKS_TYPE_TIME:
            out = PROTECT(Rf_allocVector(REALSXP, n));
            for (idx_t j = 0; j < len; j++) {
                if (!rducks_rc_direct_view_valid_at(&child_view, start + j)) REAL(out)[(R_xlen_t)j] = NA_REAL;
                else if (child_desc->scalar == RDUCKS_TYPE_TIME) REAL(out)[(R_xlen_t)j] = (double)((duckdb_time *)child_view.data)[start + j].micros / 1000000.0;
                else REAL(out)[(R_xlen_t)j] = ((double *)child_view.data)[start + j];
            }
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_DATE:
            out = PROTECT(rducks_rc_make_date_vector(n));
            for (idx_t j = 0; j < len; j++) REAL(out)[(R_xlen_t)j] = rducks_rc_direct_view_valid_at(&child_view, start + j) ? (double)((duckdb_date *)child_view.data)[start + j].days : NA_REAL;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_TIMESTAMP:
            out = PROTECT(rducks_rc_make_posixct_vector(n));
            for (idx_t j = 0; j < len; j++) REAL(out)[(R_xlen_t)j] = rducks_rc_direct_view_valid_at(&child_view, start + j) ? (double)((duckdb_timestamp *)child_view.data)[start + j].micros / 1000000.0 : NA_REAL;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_VARCHAR:
            out = PROTECT(Rf_allocVector(STRSXP, n));
            for (idx_t j = 0; j < len; j++) {
                if (!rducks_rc_direct_view_valid_at(&child_view, start + j)) SET_STRING_ELT(out, (R_xlen_t)j, NA_STRING);
                else {
                    duckdb_string_t *data = (duckdb_string_t *)child_view.data;
                    uint32_t slen = duckdb_string_t_length(data[start + j]);
                    const char *ptr = duckdb_string_t_data(&data[start + j]);
                    if (slen > (uint32_t)INT_MAX) {
                        Rf_error("Rducks VARCHAR value is too large to materialize in R");
                    }
                    SET_STRING_ELT(out, (R_xlen_t)j, Rf_mkCharLenCE(ptr, (int)slen, CE_UTF8));
                }
            }
            UNPROTECT(1);
            return out;
        default:
            break;
        }
    }
    out = PROTECT(Rf_allocVector(VECSXP, n));
    for (idx_t j = 0; j < len; j++) {
        SET_VECTOR_ELT(out, (R_xlen_t)j, rducks_rc_direct_arg(child_desc, &child_view, start + j));
    }
    UNPROTECT(1);
    return out;
}

static SEXP rducks_rc_direct_arg(const rducks_type_desc_t *desc, const rducks_rc_direct_vector_view_t *input, idx_t row) {
    SEXP out;
    if (!rducks_rc_direct_view_valid_at(input, row)) return rducks_rc_missing_arg(desc);
    if (desc->kind == RDUCKS_KIND_LIST) {
        duckdb_list_entry *entries = (duckdb_list_entry *)input->data;
        duckdb_vector child = duckdb_list_vector_get_child(input->vector);
        return rducks_rc_direct_sequence_arg(desc->child, child, (idx_t)entries[row].offset, (idx_t)entries[row].length);
    }
    if (desc->kind == RDUCKS_KIND_ARRAY) {
        duckdb_vector child = duckdb_array_vector_get_child(input->vector);
        idx_t start = 0;
        if (!rducks_rc_idx_mul(row, desc->array_size, &start)) {
            Rf_error("Rducks ARRAY child index overflow");
        }
        return rducks_rc_direct_sequence_arg(desc->child, child, start, desc->array_size);
    }
    if (desc->kind == RDUCKS_KIND_STRUCT) {
        out = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)desc->field_count));
        SEXP names = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)desc->field_count));
        for (size_t i = 0; i < desc->field_count; i++) {
            duckdb_vector child = duckdb_struct_vector_get_child(input->vector, (idx_t)i);
            rducks_rc_direct_vector_view_t child_view;
            SET_STRING_ELT(names, (R_xlen_t)i, Rf_mkChar(desc->field_names[i] ? desc->field_names[i] : ""));
            rducks_rc_direct_view_init(&child_view, child);
            SET_VECTOR_ELT(out, (R_xlen_t)i, rducks_rc_direct_arg(desc->field_types[i], &child_view, row));
        }
        Rf_setAttrib(out, R_NamesSymbol, names);
        UNPROTECT(2);
        return out;
    }
    if (desc->kind == RDUCKS_KIND_MAP) {
        duckdb_list_entry *entries = (duckdb_list_entry *)input->data;
        duckdb_vector entry_vector = duckdb_list_vector_get_child(input->vector);
        duckdb_vector key_vector = duckdb_struct_vector_get_child(entry_vector, 0);
        duckdb_vector value_vector = duckdb_struct_vector_get_child(entry_vector, 1);
        idx_t offset = (idx_t)entries[row].offset;
        idx_t len = (idx_t)entries[row].length;
        SEXP keys = PROTECT(rducks_rc_direct_sequence_arg(desc->key, key_vector, offset, len));
        SEXP values = PROTECT(rducks_rc_direct_sequence_arg(desc->value, value_vector, offset, len));
        SEXP names = PROTECT(Rf_allocVector(STRSXP, 2));
        out = PROTECT(Rf_allocVector(VECSXP, 2));
        SET_VECTOR_ELT(out, 0, keys);
        SET_VECTOR_ELT(out, 1, values);
        SET_STRING_ELT(names, 0, Rf_mkChar("keys"));
        SET_STRING_ELT(names, 1, Rf_mkChar("values"));
        Rf_setAttrib(out, R_NamesSymbol, names);
        UNPROTECT(4);
        return out;
    }
    if (desc->kind == RDUCKS_KIND_UNION) {
        /* DuckDB's pinned vector layout stores UNION as a STRUCT: child 0 is a
         * uint8 tag vector and children 1..n are member vectors. The C API has
         * no union-vector accessors, so this direct path deliberately uses the
         * struct child accessor against that tested DuckDB layout.
         */
        duckdb_vector tag_vector = duckdb_struct_vector_get_child(input->vector, 0);
        rducks_rc_direct_vector_view_t tag_view;
        rducks_rc_direct_view_init(&tag_view, tag_vector);
        if (!rducks_rc_direct_view_valid_at(&tag_view, row)) return R_NilValue;
        uint8_t tag = ((uint8_t *)tag_view.data)[row];
        if ((size_t)tag >= desc->field_count) return R_NilValue;
        duckdb_vector member_vector = duckdb_struct_vector_get_child(input->vector, (idx_t)tag + 1U);
        rducks_rc_direct_vector_view_t member_view;
        rducks_rc_direct_view_init(&member_view, member_vector);
        SEXP payload = PROTECT(rducks_rc_direct_arg(desc->field_types[tag], &member_view, row));
        out = PROTECT(rducks_rc_make_union_value(desc->field_names[tag], payload));
        UNPROTECT(2);
        return out;
    }
    if (desc->kind == RDUCKS_KIND_ENUM) {
        uint32_t index = rducks_rc_enum_index_from_data(desc, input->data, row);
        return rducks_rc_make_enum(desc, index < desc->field_count ? (int32_t)index : -1);
    }
    if (desc->kind == RDUCKS_KIND_DECIMAL) {
        uint8_t bytes[16];
        int storage_width = rducks_rc_decimal_storage_width(desc);
        memset(bytes, 0, sizeof(bytes));
        if (storage_width == 2) {
            int16_t *data = (int16_t *)input->data;
            uint16_t u;
            memcpy(&u, &data[row], sizeof(u));
            bytes[0] = (uint8_t)(u & 0xffU);
            bytes[1] = (uint8_t)((u >> 8) & 0xffU);
        } else if (storage_width == 4) {
            int32_t *data = (int32_t *)input->data;
            uint32_t u;
            memcpy(&u, &data[row], sizeof(u));
            for (int i = 0; i < 4; i++) bytes[i] = (uint8_t)((u >> (8 * i)) & 0xffU);
        } else if (storage_width == 8) {
            int64_t *data = (int64_t *)input->data;
            uint64_t u;
            memcpy(&u, &data[row], sizeof(u));
            rducks_rc_u64_to_le_bytes(u, bytes);
        } else {
            duckdb_hugeint *data = (duckdb_hugeint *)input->data;
            rducks_rc_u64_to_le_bytes(data[row].lower, bytes);
            uint64_t upper;
            memcpy(&upper, &data[row].upper, sizeof(upper));
            rducks_rc_u64_to_le_bytes(upper, bytes + 8);
        }
        return rducks_rc_make_decimal_object_from_storage_bytes(bytes, (size_t)storage_width,
                                                                desc->decimal_width, desc->decimal_scale);
    }
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
    case RDUCKS_TYPE_I64: {
        int64_t *data = (int64_t *)input->data;
        uint8_t bytes[8];
        uint64_t u;
        memcpy(&u, &data[row], sizeof(u));
        rducks_rc_u64_to_le_bytes(u, bytes);
        return rducks_rc_make_integer_object_from_le_bytes(bytes, 8, 1, "rducks_bigint");
    }
    case RDUCKS_TYPE_U64: {
        uint64_t *data = (uint64_t *)input->data;
        uint8_t bytes[8];
        rducks_rc_u64_to_le_bytes(data[row], bytes);
        return rducks_rc_make_integer_object_from_le_bytes(bytes, 8, 0, "rducks_ubigint");
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
        if (len > (uint32_t)INT_MAX) {
            Rf_error("Rducks VARCHAR value is too large to materialize in R");
        }
        out = PROTECT(Rf_allocVector(STRSXP, 1));
        SET_STRING_ELT(out, 0, Rf_mkCharLenCE(ptr, (int)len, CE_UTF8));
        UNPROTECT(1);
        return out;
    }
    case RDUCKS_TYPE_BLOB:
    case RDUCKS_TYPE_GEOMETRY: {
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
    case RDUCKS_TYPE_HUGEINT: {
        duckdb_hugeint *data = (duckdb_hugeint *)input->data;
        uint8_t bytes[16];
        rducks_rc_u64_to_le_bytes(data[row].lower, bytes);
        uint64_t upper;
        memcpy(&upper, &data[row].upper, sizeof(upper));
        rducks_rc_u64_to_le_bytes(upper, bytes + 8);
        return rducks_rc_make_integer_object_from_le_bytes(bytes, 16, 1, "rducks_hugeint");
    }
    case RDUCKS_TYPE_UHUGEINT: {
        duckdb_uhugeint *data = (duckdb_uhugeint *)input->data;
        uint8_t bytes[16];
        rducks_rc_u64_to_le_bytes(data[row].lower, bytes);
        rducks_rc_u64_to_le_bytes(data[row].upper, bytes + 8);
        return rducks_rc_make_integer_object_from_le_bytes(bytes, 16, 0, "rducks_uhugeint");
    }
    case RDUCKS_TYPE_UUID: {
        duckdb_hugeint *data = (duckdb_hugeint *)input->data;
        return rducks_rc_make_uuid_from_hugeint(data[row]);
    }
    case RDUCKS_TYPE_INTERVAL: {
        duckdb_interval *data = (duckdb_interval *)input->data;
        return rducks_rc_make_interval_object(data[row]);
    }
    case RDUCKS_TYPE_BIT: {
        duckdb_string_t *data = (duckdb_string_t *)input->data;
        uint32_t len = duckdb_string_t_length(data[row]);
        const char *ptr = duckdb_string_t_data(&data[row]);
        return rducks_rc_make_bits_from_payload(ptr, len);
    }
    default:
        return R_NilValue;
    }
}

static SEXP rducks_rc_make_classed_character_vector(R_xlen_t n, const char *class_name) {
    SEXP out = PROTECT(Rf_allocVector(STRSXP, n));
    SEXP cls = PROTECT(Rf_allocVector(STRSXP, 2));
    SET_STRING_ELT(cls, 0, Rf_mkChar(class_name));
    SET_STRING_ELT(cls, 1, Rf_mkChar("character"));
    Rf_setAttrib(out, R_ClassSymbol, cls);
    UNPROTECT(2);
    return out;
}

static SEXP rducks_rc_make_decimal_vector(R_xlen_t n, int width, int scale) {
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 3));
    SEXP values = PROTECT(Rf_allocVector(STRSXP, n));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 3));
    SEXP cls = PROTECT(Rf_mkString("rducks_decimal"));
    SEXP width_sexp = PROTECT(Rf_ScalarInteger(width));
    SEXP scale_sexp = PROTECT(Rf_ScalarInteger(scale));
    SET_VECTOR_ELT(out, 0, values);
    SET_VECTOR_ELT(out, 1, width_sexp);
    SET_VECTOR_ELT(out, 2, scale_sexp);
    SET_STRING_ELT(names, 0, Rf_mkChar("value"));
    SET_STRING_ELT(names, 1, Rf_mkChar("width"));
    SET_STRING_ELT(names, 2, Rf_mkChar("scale"));
    Rf_setAttrib(out, R_NamesSymbol, names);
    Rf_setAttrib(out, R_ClassSymbol, cls);
    UNPROTECT(6);
    return out;
}

static SEXP rducks_rc_make_interval_vector(R_xlen_t n) {
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 3));
    SEXP months = PROTECT(Rf_allocVector(INTSXP, n));
    SEXP days = PROTECT(Rf_allocVector(INTSXP, n));
    SEXP micros = PROTECT(rducks_rc_make_classed_character_vector(n, "rducks_bigint"));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 3));
    SEXP cls = PROTECT(Rf_mkString("rducks_interval"));
    SET_VECTOR_ELT(out, 0, months);
    SET_VECTOR_ELT(out, 1, days);
    SET_VECTOR_ELT(out, 2, micros);
    SET_STRING_ELT(names, 0, Rf_mkChar("months"));
    SET_STRING_ELT(names, 1, Rf_mkChar("days"));
    SET_STRING_ELT(names, 2, Rf_mkChar("micros"));
    Rf_setAttrib(out, R_NamesSymbol, names);
    Rf_setAttrib(out, R_ClassSymbol, cls);
    UNPROTECT(6);
    return out;
}

static void rducks_rc_set_string_from_signed_bytes(SEXP out, R_xlen_t i, const uint8_t *bytes,
                                                   size_t width, int signed_value) {
    char buf[160];
    size_t len = rducks_rc_int_le_bytes_to_decimal_buf(bytes, width, signed_value, buf, sizeof(buf));
    SET_STRING_ELT(out, i, Rf_mkCharLenCE(buf, (int)len, CE_UTF8));
}

static void rducks_rc_decimal_string_from_storage(SEXP values, R_xlen_t i, const uint8_t *bytes,
                                                  size_t storage_width, int width, int scale) {
    char integer_buf[160];
    size_t integer_len = rducks_rc_int_le_bytes_to_decimal_buf(bytes, storage_width, 1, integer_buf, sizeof(integer_buf));
    int neg = integer_len > 0 && integer_buf[0] == '-';
    const char *digits = integer_buf + (neg ? 1 : 0);
    size_t digit_len = integer_len - (neg ? 1U : 0U);
    digits = rducks_rc_skip_zeros(digits, &digit_len);
    if (digit_len == 0) {
        digits = "0";
        digit_len = 1;
        neg = 0;
    }
    size_t padded_len = scale > 0 && digit_len <= (size_t)scale ? (size_t)scale + 1U : digit_len;
    char *padded = (char *)R_alloc(padded_len + 1U, sizeof(char));
    size_t pad = padded_len - digit_len;
    memset(padded, '0', pad);
    memcpy(padded + pad, digits, digit_len);
    padded[padded_len] = '\0';
    size_t whole_len = scale > 0 ? padded_len - (size_t)scale : padded_len;
    const char *whole = rducks_rc_skip_zeros(padded, &whole_len);
    if (whole_len == 0) {
        whole = "0";
        whole_len = 1;
    }
    size_t out_len = (neg ? 1U : 0U) + whole_len + (scale > 0 ? 1U + (size_t)scale : 0U);
    char *buf = (char *)R_alloc(out_len + 1U, sizeof(char));
    size_t pos = 0;
    if (neg) buf[pos++] = '-';
    memcpy(buf + pos, whole, whole_len);
    pos += whole_len;
    if (scale > 0) {
        buf[pos++] = '.';
        memcpy(buf + pos, padded + padded_len - (size_t)scale, (size_t)scale);
        pos += (size_t)scale;
    }
    buf[pos] = '\0';
    SET_STRING_ELT(values, i, Rf_mkCharLenCE(buf, (int)out_len, CE_UTF8));
    (void)width;
}

static SEXP rducks_rc_direct_column_nulls(const rducks_rc_direct_vector_view_t *view, idx_t n) {
    SEXP out = PROTECT(Rf_allocVector(LGLSXP, (R_xlen_t)n));
    for (idx_t row = 0; row < n; row++) {
        LOGICAL(out)[(R_xlen_t)row] = rducks_rc_direct_view_valid_at(view, row) ? FALSE : TRUE;
    }
    UNPROTECT(1);
    return out;
}

static SEXP rducks_rc_direct_column_values(const rducks_type_desc_t *desc, duckdb_vector vector, idx_t n,
                                           char *err_msg, size_t err_cap) {
    rducks_rc_direct_vector_view_t view;
    SEXP out;
    rducks_rc_direct_view_init(&view, vector);

    if (desc->kind == RDUCKS_KIND_ENUM) {
        out = PROTECT(rducks_rc_make_enum_vector(desc, (R_xlen_t)n));
        for (idx_t row = 0; row < n; row++) {
            if (!rducks_rc_direct_view_valid_at(&view, row)) {
                INTEGER(out)[(R_xlen_t)row] = NA_INTEGER;
            } else {
                uint32_t index = rducks_rc_enum_index_from_data(desc, view.data, row);
                INTEGER(out)[(R_xlen_t)row] = index < desc->field_count ? (int)index + 1 : NA_INTEGER;
            }
        }
        UNPROTECT(1);
        return out;
    }

    if (desc->kind == RDUCKS_KIND_DECIMAL) {
        int storage_width = rducks_rc_decimal_storage_width(desc);
        out = PROTECT(rducks_rc_make_decimal_vector((R_xlen_t)n, desc->decimal_width, desc->decimal_scale));
        SEXP values = VECTOR_ELT(out, 0);
        for (idx_t row = 0; row < n; row++) {
            uint8_t bytes[16];
            memset(bytes, 0, sizeof(bytes));
            if (!rducks_rc_direct_view_valid_at(&view, row)) {
                SET_STRING_ELT(values, (R_xlen_t)row, NA_STRING);
                continue;
            }
            if (storage_width == 2) {
                int16_t *data = (int16_t *)view.data;
                uint16_t u;
                memcpy(&u, &data[row], sizeof(u));
                bytes[0] = (uint8_t)(u & 0xffU);
                bytes[1] = (uint8_t)((u >> 8) & 0xffU);
            } else if (storage_width == 4) {
                int32_t *data = (int32_t *)view.data;
                uint32_t u;
                memcpy(&u, &data[row], sizeof(u));
                for (int i = 0; i < 4; i++) bytes[i] = (uint8_t)((u >> (8 * i)) & 0xffU);
            } else if (storage_width == 8) {
                int64_t *data = (int64_t *)view.data;
                uint64_t u;
                memcpy(&u, &data[row], sizeof(u));
                rducks_rc_u64_to_le_bytes(u, bytes);
            } else {
                duckdb_hugeint *data = (duckdb_hugeint *)view.data;
                rducks_rc_u64_to_le_bytes(data[row].lower, bytes);
                uint64_t upper;
                memcpy(&upper, &data[row].upper, sizeof(upper));
                rducks_rc_u64_to_le_bytes(upper, bytes + 8);
            }
            rducks_rc_decimal_string_from_storage(values, (R_xlen_t)row, bytes, (size_t)storage_width,
                                                  desc->decimal_width, desc->decimal_scale);
        }
        UNPROTECT(1);
        return out;
    }

    if (desc->kind == RDUCKS_KIND_SCALAR) {
        switch (desc->scalar) {
        case RDUCKS_TYPE_BOOL:
            out = PROTECT(Rf_allocVector(LGLSXP, (R_xlen_t)n));
            for (idx_t row = 0; row < n; row++) LOGICAL(out)[(R_xlen_t)row] = rducks_rc_direct_view_valid_at(&view, row) ? (((bool *)view.data)[row] ? TRUE : FALSE) : NA_LOGICAL;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_I8:
            out = PROTECT(Rf_allocVector(INTSXP, (R_xlen_t)n));
            for (idx_t row = 0; row < n; row++) INTEGER(out)[(R_xlen_t)row] = rducks_rc_direct_view_valid_at(&view, row) ? (int)((int8_t *)view.data)[row] : NA_INTEGER;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_U8:
            out = PROTECT(Rf_allocVector(INTSXP, (R_xlen_t)n));
            for (idx_t row = 0; row < n; row++) INTEGER(out)[(R_xlen_t)row] = rducks_rc_direct_view_valid_at(&view, row) ? (int)((uint8_t *)view.data)[row] : NA_INTEGER;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_I16:
            out = PROTECT(Rf_allocVector(INTSXP, (R_xlen_t)n));
            for (idx_t row = 0; row < n; row++) INTEGER(out)[(R_xlen_t)row] = rducks_rc_direct_view_valid_at(&view, row) ? (int)((int16_t *)view.data)[row] : NA_INTEGER;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_U16:
            out = PROTECT(Rf_allocVector(INTSXP, (R_xlen_t)n));
            for (idx_t row = 0; row < n; row++) INTEGER(out)[(R_xlen_t)row] = rducks_rc_direct_view_valid_at(&view, row) ? (int)((uint16_t *)view.data)[row] : NA_INTEGER;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_I32:
            out = PROTECT(Rf_allocVector(INTSXP, (R_xlen_t)n));
            for (idx_t row = 0; row < n; row++) INTEGER(out)[(R_xlen_t)row] = rducks_rc_direct_view_valid_at(&view, row) ? (int)((int32_t *)view.data)[row] : NA_INTEGER;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_U32:
            out = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t)n));
            for (idx_t row = 0; row < n; row++) REAL(out)[(R_xlen_t)row] = rducks_rc_direct_view_valid_at(&view, row) ? (double)((uint32_t *)view.data)[row] : NA_REAL;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_I64:
        case RDUCKS_TYPE_U64: {
            int signed_value = desc->scalar == RDUCKS_TYPE_I64;
            out = PROTECT(rducks_rc_make_classed_character_vector((R_xlen_t)n, signed_value ? "rducks_bigint" : "rducks_ubigint"));
            for (idx_t row = 0; row < n; row++) {
                uint8_t bytes[8];
                if (!rducks_rc_direct_view_valid_at(&view, row)) {
                    SET_STRING_ELT(out, (R_xlen_t)row, NA_STRING);
                } else if (signed_value) {
                    int64_t *data = (int64_t *)view.data;
                    uint64_t u;
                    memcpy(&u, &data[row], sizeof(u));
                    rducks_rc_u64_to_le_bytes(u, bytes);
                    rducks_rc_set_string_from_signed_bytes(out, (R_xlen_t)row, bytes, 8, 1);
                } else {
                    rducks_rc_u64_to_le_bytes(((uint64_t *)view.data)[row], bytes);
                    rducks_rc_set_string_from_signed_bytes(out, (R_xlen_t)row, bytes, 8, 0);
                }
            }
            UNPROTECT(1);
            return out;
        }
        case RDUCKS_TYPE_F32:
            out = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t)n));
            for (idx_t row = 0; row < n; row++) REAL(out)[(R_xlen_t)row] = rducks_rc_direct_view_valid_at(&view, row) ? (double)((float *)view.data)[row] : NA_REAL;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_F64:
            out = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t)n));
            for (idx_t row = 0; row < n; row++) REAL(out)[(R_xlen_t)row] = rducks_rc_direct_view_valid_at(&view, row) ? ((double *)view.data)[row] : NA_REAL;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_VARCHAR:
            out = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)n));
            for (idx_t row = 0; row < n; row++) {
                if (!rducks_rc_direct_view_valid_at(&view, row)) {
                    SET_STRING_ELT(out, (R_xlen_t)row, NA_STRING);
                } else {
                    duckdb_string_t *data = (duckdb_string_t *)view.data;
                    uint32_t len = duckdb_string_t_length(data[row]);
                    const char *ptr = duckdb_string_t_data(&data[row]);
                    if (len > (uint32_t)INT_MAX) {
                        rducks_format_error_message(err_msg, err_cap, "Rducks VARCHAR value is too large to materialize in R");
                        UNPROTECT(1);
                        return R_NilValue;
                    }
                    SET_STRING_ELT(out, (R_xlen_t)row, Rf_mkCharLenCE(ptr, (int)len, CE_UTF8));
                }
            }
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_BLOB:
        case RDUCKS_TYPE_GEOMETRY:
            out = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)n));
            for (idx_t row = 0; row < n; row++) {
                if (!rducks_rc_direct_view_valid_at(&view, row)) {
                    SET_VECTOR_ELT(out, (R_xlen_t)row, R_NilValue);
                } else {
                    duckdb_string_t *data = (duckdb_string_t *)view.data;
                    uint32_t len = duckdb_string_t_length(data[row]);
                    const char *ptr = duckdb_string_t_data(&data[row]);
                    SEXP raw = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)len));
                    if (len) memcpy(RAW(raw), ptr, len);
                    SET_VECTOR_ELT(out, (R_xlen_t)row, raw);
                    UNPROTECT(1);
                }
            }
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_DATE:
            out = PROTECT(rducks_rc_make_date_vector((R_xlen_t)n));
            for (idx_t row = 0; row < n; row++) REAL(out)[(R_xlen_t)row] = rducks_rc_direct_view_valid_at(&view, row) ? (double)((duckdb_date *)view.data)[row].days : NA_REAL;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_TIME:
            out = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t)n));
            for (idx_t row = 0; row < n; row++) REAL(out)[(R_xlen_t)row] = rducks_rc_direct_view_valid_at(&view, row) ? (double)((duckdb_time *)view.data)[row].micros / 1000000.0 : NA_REAL;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_TIMESTAMP:
            out = PROTECT(rducks_rc_make_posixct_vector((R_xlen_t)n));
            for (idx_t row = 0; row < n; row++) REAL(out)[(R_xlen_t)row] = rducks_rc_direct_view_valid_at(&view, row) ? (double)((duckdb_timestamp *)view.data)[row].micros / 1000000.0 : NA_REAL;
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_HUGEINT:
        case RDUCKS_TYPE_UHUGEINT: {
            int signed_value = desc->scalar == RDUCKS_TYPE_HUGEINT;
            out = PROTECT(rducks_rc_make_classed_character_vector((R_xlen_t)n, signed_value ? "rducks_hugeint" : "rducks_uhugeint"));
            for (idx_t row = 0; row < n; row++) {
                uint8_t bytes[16];
                if (!rducks_rc_direct_view_valid_at(&view, row)) {
                    SET_STRING_ELT(out, (R_xlen_t)row, NA_STRING);
                } else if (signed_value) {
                    duckdb_hugeint *data = (duckdb_hugeint *)view.data;
                    rducks_rc_u64_to_le_bytes(data[row].lower, bytes);
                    uint64_t upper;
                    memcpy(&upper, &data[row].upper, sizeof(upper));
                    rducks_rc_u64_to_le_bytes(upper, bytes + 8);
                    rducks_rc_set_string_from_signed_bytes(out, (R_xlen_t)row, bytes, 16, 1);
                } else {
                    duckdb_uhugeint *data = (duckdb_uhugeint *)view.data;
                    rducks_rc_u64_to_le_bytes(data[row].lower, bytes);
                    rducks_rc_u64_to_le_bytes(data[row].upper, bytes + 8);
                    rducks_rc_set_string_from_signed_bytes(out, (R_xlen_t)row, bytes, 16, 0);
                }
            }
            UNPROTECT(1);
            return out;
        }
        case RDUCKS_TYPE_UUID:
            out = PROTECT(rducks_rc_make_classed_character_vector((R_xlen_t)n, "rducks_uuid"));
            for (idx_t row = 0; row < n; row++) {
                if (!rducks_rc_direct_view_valid_at(&view, row)) {
                    SET_STRING_ELT(out, (R_xlen_t)row, NA_STRING);
                } else {
                    SEXP uuid = PROTECT(rducks_rc_make_uuid_from_hugeint(((duckdb_hugeint *)view.data)[row]));
                    SET_STRING_ELT(out, (R_xlen_t)row, STRING_ELT(uuid, 0));
                    UNPROTECT(1);
                }
            }
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_INTERVAL:
            out = PROTECT(rducks_rc_make_interval_vector((R_xlen_t)n));
            for (idx_t row = 0; row < n; row++) {
                SEXP months = VECTOR_ELT(out, 0);
                SEXP days = VECTOR_ELT(out, 1);
                SEXP micros = VECTOR_ELT(out, 2);
                if (!rducks_rc_direct_view_valid_at(&view, row)) {
                    INTEGER(months)[(R_xlen_t)row] = NA_INTEGER;
                    INTEGER(days)[(R_xlen_t)row] = NA_INTEGER;
                    SET_STRING_ELT(micros, (R_xlen_t)row, NA_STRING);
                } else {
                    duckdb_interval value = ((duckdb_interval *)view.data)[row];
                    uint8_t bytes[8];
                    uint64_t u;
                    INTEGER(months)[(R_xlen_t)row] = value.months;
                    INTEGER(days)[(R_xlen_t)row] = value.days;
                    memcpy(&u, &value.micros, sizeof(u));
                    rducks_rc_u64_to_le_bytes(u, bytes);
                    rducks_rc_set_string_from_signed_bytes(micros, (R_xlen_t)row, bytes, 8, 1);
                }
            }
            UNPROTECT(1);
            return out;
        case RDUCKS_TYPE_BIT:
            out = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)n));
            for (idx_t row = 0; row < n; row++) {
                if (!rducks_rc_direct_view_valid_at(&view, row)) {
                    SET_VECTOR_ELT(out, (R_xlen_t)row, R_NilValue);
                } else {
                    duckdb_string_t *data = (duckdb_string_t *)view.data;
                    uint32_t len = duckdb_string_t_length(data[row]);
                    const char *ptr = duckdb_string_t_data(&data[row]);
                    SET_VECTOR_ELT(out, (R_xlen_t)row, rducks_rc_make_bits_from_payload(ptr, len));
                }
            }
            UNPROTECT(1);
            return out;
        default:
            break;
        }
    }

    out = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)n));
    for (idx_t row = 0; row < n; row++) {
        if (!rducks_rc_direct_view_valid_at(&view, row)) {
            SET_VECTOR_ELT(out, (R_xlen_t)row, R_NilValue);
        } else {
            SET_VECTOR_ELT(out, (R_xlen_t)row, rducks_rc_direct_arg(desc, &view, row));
        }
    }
    if (desc->kind == RDUCKS_KIND_UNION) {
        SEXP cls = PROTECT(Rf_mkString("rducks_union_list"));
        Rf_setAttrib(out, R_ClassSymbol, cls);
        UNPROTECT(1);
    }
    if (!rducks_rc_direct_type_supported(desc)) {
        rducks_format_error_message(err_msg, err_cap, "direct marshalling is not implemented for this UDF signature");
    }
    UNPROTECT(1);
    return out;
}

static SEXP rducks_rc_direct_prepare_inputs(rducks_r_scalar_meta_t *meta, duckdb_data_chunk input,
                                            idx_t n, int *protect_count,
                                            char *err_msg, size_t err_cap) {
    SEXP prepared;
    SEXP columns;
    SEXP nulls;
    SEXP top_level_null;
    SEXP n_sexp;
    SEXP dynamic_arg_tokens;
    SEXP names;

    if (n > (idx_t)R_XLEN_T_MAX) {
        rducks_format_error_message(err_msg, err_cap, "Rducks chunk is too large to materialize in R");
        return R_NilValue;
    }

    prepared = PROTECT(Rf_allocVector(VECSXP, 5));
    (*protect_count)++;
    columns = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)meta->arity));
    (*protect_count)++;
    nulls = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)meta->arity));
    (*protect_count)++;
    top_level_null = PROTECT(Rf_allocVector(LGLSXP, (R_xlen_t)n));
    (*protect_count)++;
    n_sexp = PROTECT(Rf_ScalarReal((double)n));
    (*protect_count)++;
    dynamic_arg_tokens = PROTECT(rducks_dynamic_arg_tokens_sexp(meta));
    (*protect_count)++;
    names = PROTECT(Rf_allocVector(STRSXP, 5));
    (*protect_count)++;

    for (idx_t row = 0; row < n; row++) LOGICAL(top_level_null)[(R_xlen_t)row] = FALSE;

    for (size_t col = 0; col < meta->arity; col++) {
        duckdb_vector vector = duckdb_data_chunk_get_vector(input, (idx_t)col);
        rducks_rc_direct_vector_view_t view;
        rducks_rc_direct_view_init(&view, vector);
        SEXP col_nulls = PROTECT(rducks_rc_direct_column_nulls(&view, n));
        SEXP values = PROTECT(rducks_rc_direct_column_values(meta->args[col], vector, n, err_msg, err_cap));
        if (err_msg[0]) {
            UNPROTECT(2);
            return R_NilValue;
        }
        for (idx_t row = 0; row < n; row++) {
            if (LOGICAL(col_nulls)[(R_xlen_t)row] == TRUE) LOGICAL(top_level_null)[(R_xlen_t)row] = TRUE;
        }
        SET_VECTOR_ELT(columns, (R_xlen_t)col, values);
        SET_VECTOR_ELT(nulls, (R_xlen_t)col, col_nulls);
        UNPROTECT(2);
    }

    SET_VECTOR_ELT(prepared, 0, columns);
    SET_VECTOR_ELT(prepared, 1, nulls);
    SET_VECTOR_ELT(prepared, 2, top_level_null);
    SET_VECTOR_ELT(prepared, 3, n_sexp);
    SET_VECTOR_ELT(prepared, 4, dynamic_arg_tokens);
    SET_STRING_ELT(names, 0, Rf_mkChar("columns"));
    SET_STRING_ELT(names, 1, Rf_mkChar("nulls"));
    SET_STRING_ELT(names, 2, Rf_mkChar("top_level_null"));
    SET_STRING_ELT(names, 3, Rf_mkChar("n"));
    SET_STRING_ELT(names, 4, Rf_mkChar("dynamic_arg_tokens"));
    Rf_setAttrib(prepared, R_NamesSymbol, names);
    return prepared;
}

static int rducks_rc_write_direct_output(const rducks_type_desc_t *desc, rducks_rc_direct_vector_view_t *output,
                                         idx_t row, SEXP value, char *err_msg, size_t err_cap);

static int rducks_rc_write_direct_results(rducks_r_scalar_meta_t *meta, SEXP results,
                                          duckdb_vector output, idx_t n,
                                          char *err_msg, size_t err_cap) {
    if (TYPEOF(results) != VECSXP || XLENGTH(results) != (R_xlen_t)n) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC vectorized R function or marshal error");
        return 0;
    }
    rducks_rc_direct_vector_view_t output_view;
    rducks_rc_direct_view_init(&output_view, output);
    for (idx_t row = 0; row < n; row++) {
        SEXP value = VECTOR_ELT(results, (R_xlen_t)row);
        if (!rducks_rc_write_direct_output(meta->return_desc, &output_view, row, value, err_msg, err_cap)) {
            return 0;
        }
    }
    return 1;
}

static int rducks_rc_value_is_null_for_output(const rducks_type_desc_t *desc, SEXP value) {
    if (value == R_NilValue) return 1;
    if (desc->kind == RDUCKS_KIND_DECIMAL) {
        if (TYPEOF(value) != VECSXP || XLENGTH(value) < 1) return 0;
        SEXP values = VECTOR_ELT(value, 0);
        return TYPEOF(values) == STRSXP && XLENGTH(values) > 0 && STRING_ELT(values, 0) == NA_STRING;
    }
    if (desc->kind == RDUCKS_KIND_ENUM) {
        if (TYPEOF(value) == STRSXP && XLENGTH(value) > 0) return STRING_ELT(value, 0) == NA_STRING;
        if (TYPEOF(value) == INTSXP && XLENGTH(value) > 0 && Rf_inherits(value, "factor")) {
            return INTEGER(value)[0] == NA_INTEGER;
        }
        return 0;
    }
    if (desc->kind != RDUCKS_KIND_SCALAR) return 0;
    if (desc->scalar == RDUCKS_TYPE_F32 || desc->scalar == RDUCKS_TYPE_F64) {
        if (TYPEOF(value) != REALSXP || XLENGTH(value) < 1) return 0;
        return ISNA(REAL(value)[0]);
    }
    if (desc->scalar == RDUCKS_TYPE_VARCHAR || desc->scalar == RDUCKS_TYPE_I64 || desc->scalar == RDUCKS_TYPE_U64 ||
        desc->scalar == RDUCKS_TYPE_HUGEINT || desc->scalar == RDUCKS_TYPE_UHUGEINT || desc->scalar == RDUCKS_TYPE_UUID) {
        return TYPEOF(value) == STRSXP && XLENGTH(value) > 0 && STRING_ELT(value, 0) == NA_STRING;
    }
    if (desc->scalar == RDUCKS_TYPE_INTERVAL) {
        if (TYPEOF(value) != VECSXP || XLENGTH(value) < 3) return 0;
        SEXP months = VECTOR_ELT(value, 0);
        SEXP days = VECTOR_ELT(value, 1);
        SEXP micros = VECTOR_ELT(value, 2);
        if (TYPEOF(months) == INTSXP && XLENGTH(months) > 0 && INTEGER(months)[0] == NA_INTEGER) return 1;
        if (TYPEOF(days) == INTSXP && XLENGTH(days) > 0 && INTEGER(days)[0] == NA_INTEGER) return 1;
        if (TYPEOF(micros) == STRSXP && XLENGTH(micros) > 0 && STRING_ELT(micros, 0) == NA_STRING) return 1;
    }
    if (desc->scalar == RDUCKS_TYPE_BLOB || desc->scalar == RDUCKS_TYPE_GEOMETRY || desc->scalar == RDUCKS_TYPE_BIT) return 0;
    if (TYPEOF(value) == INTSXP && XLENGTH(value) > 0) return INTEGER(value)[0] == NA_INTEGER;
    if (TYPEOF(value) == LGLSXP && XLENGTH(value) > 0) return LOGICAL(value)[0] == NA_LOGICAL;
    if (TYPEOF(value) == REALSXP && XLENGTH(value) > 0) return ISNA(REAL(value)[0]);
    return 0;
}

static int rducks_rc_write_null_direct_output(const rducks_type_desc_t *desc,
                                              rducks_rc_direct_vector_view_t *output,
                                              idx_t row, char *err_msg, size_t err_cap) {
    if (!desc || !output) return 1;
    rducks_rc_output_set_null(output, row);
    if (desc->kind == RDUCKS_KIND_LIST || desc->kind == RDUCKS_KIND_MAP) {
        duckdb_list_entry *entries = (duckdb_list_entry *)output->data;
        if (entries) {
            entries[row].offset = duckdb_list_vector_get_size(output->vector);
            entries[row].length = 0U;
        }
        return 1;
    }
    if (desc->kind == RDUCKS_KIND_ARRAY) {
        duckdb_vector child = duckdb_array_vector_get_child(output->vector);
        rducks_rc_direct_vector_view_t child_view;
        idx_t base = 0;
        if (!child) return 1;
        if (!rducks_rc_idx_mul(row, desc->array_size, &base)) {
            rducks_format_error_message(err_msg, err_cap, "Rducks ARRAY null child index overflow");
            return 0;
        }
        rducks_rc_direct_view_init(&child_view, child);
        for (idx_t j = 0; j < desc->array_size; j++) {
            idx_t child_row = 0;
            if (!rducks_rc_idx_add(base, j, &child_row) ||
                !rducks_rc_write_null_direct_output(desc->child, &child_view, child_row, err_msg, err_cap)) {
                if (!err_msg[0]) rducks_format_error_message(err_msg, err_cap, "failed to write DuckDB ARRAY null child value");
                return 0;
            }
        }
        return 1;
    }
    if (desc->kind == RDUCKS_KIND_STRUCT) {
        for (size_t i = 0; i < desc->field_count; i++) {
            duckdb_vector child = duckdb_struct_vector_get_child(output->vector, (idx_t)i);
            rducks_rc_direct_vector_view_t child_view;
            if (!child) continue;
            rducks_rc_direct_view_init(&child_view, child);
            if (!rducks_rc_write_null_direct_output(desc->field_types[i], &child_view, row, err_msg, err_cap)) {
                if (!err_msg[0]) rducks_format_error_message(err_msg, err_cap, "failed to write DuckDB STRUCT null child value");
                return 0;
            }
        }
        return 1;
    }
    if (desc->kind == RDUCKS_KIND_UNION) {
        /* See the UNION input path: DuckDB stores UNION vectors as STRUCT
         * vectors with a tag child followed by one child per member.
         */
        duckdb_vector tag_vector = duckdb_struct_vector_get_child(output->vector, 0);
        rducks_rc_direct_vector_view_t tag_view;
        if (tag_vector) {
            rducks_rc_direct_view_init(&tag_view, tag_vector);
            rducks_rc_output_set_null(&tag_view, row);
        }
        for (size_t i = 0; i < desc->field_count; i++) {
            duckdb_vector member_vector = duckdb_struct_vector_get_child(output->vector, (idx_t)i + 1U);
            rducks_rc_direct_vector_view_t member_view;
            if (!member_vector) continue;
            rducks_rc_direct_view_init(&member_view, member_vector);
            if (!rducks_rc_write_null_direct_output(desc->field_types[i], &member_view, row, err_msg, err_cap)) {
                if (!err_msg[0]) rducks_format_error_message(err_msg, err_cap, "failed to write DuckDB UNION null member value");
                return 0;
            }
        }
        return 1;
    }
    return 1;
}

static int rducks_rc_write_direct_output(const rducks_type_desc_t *desc, rducks_rc_direct_vector_view_t *output,
                                         idx_t row, SEXP value, char *err_msg, size_t err_cap) {
    if (rducks_rc_value_is_null_for_output(desc, value)) {
        return rducks_rc_write_null_direct_output(desc, output, row, err_msg, err_cap);
    }
    rducks_rc_output_set_valid_if_needed(output, row);
    if (desc->kind == RDUCKS_KIND_LIST) {
        R_xlen_t len = XLENGTH(value);
        idx_t offset = duckdb_list_vector_get_size(output->vector);
        idx_t required = 0;
        duckdb_list_entry *entries = (duckdb_list_entry *)output->data;
        duckdb_vector child;
        rducks_rc_direct_vector_view_t child_view;
        if (len < 0 || !rducks_rc_idx_add(offset, (idx_t)len, &required)) {
            rducks_format_error_message(err_msg, err_cap, "Rducks LIST return length is invalid");
            return 0;
        }
        if (duckdb_list_vector_reserve(output->vector, required) == DuckDBError) {
            rducks_format_error_message(err_msg, err_cap, "failed to reserve DuckDB LIST child storage");
            return 0;
        }
        child = duckdb_list_vector_get_child(output->vector);
        rducks_rc_direct_view_init(&child_view, child);
        for (R_xlen_t j = 0; j < len; j++) {
            int ok = 1;
            SEXP element = PROTECT(rducks_rc_vector_value_at(value, (idx_t)j, &ok));
            if (!ok || !rducks_rc_write_direct_output(desc->child, &child_view, offset + (idx_t)j, element, err_msg, err_cap)) {
                UNPROTECT(1);
                if (ok && !err_msg[0]) rducks_format_error_message(err_msg, err_cap, "failed to write DuckDB LIST child value");
                return 0;
            }
            UNPROTECT(1);
        }
        if (duckdb_list_vector_set_size(output->vector, required) == DuckDBError) {
            rducks_format_error_message(err_msg, err_cap, "failed to commit DuckDB LIST child storage");
            return 0;
        }
        entries[row].offset = offset;
        entries[row].length = (uint64_t)len;
        return 1;
    }
    if (desc->kind == RDUCKS_KIND_ARRAY) {
        R_xlen_t len = XLENGTH(value);
        duckdb_vector child;
        rducks_rc_direct_vector_view_t child_view;
        idx_t base = 0;
        if (len != (R_xlen_t)desc->array_size) {
            rducks_format_error_message(err_msg, err_cap, "Rducks ARRAY return value must have length %llu", (unsigned long long)desc->array_size);
            return 0;
        }
        if (!rducks_rc_idx_mul(row, desc->array_size, &base)) {
            rducks_format_error_message(err_msg, err_cap, "Rducks ARRAY child index overflow");
            return 0;
        }
        child = duckdb_array_vector_get_child(output->vector);
        rducks_rc_direct_view_init(&child_view, child);
        for (R_xlen_t j = 0; j < len; j++) {
            int ok = 1;
            SEXP element = PROTECT(rducks_rc_vector_value_at(value, (idx_t)j, &ok));
            idx_t child_row = 0;
            if (!rducks_rc_idx_add(base, (idx_t)j, &child_row) ||
                !ok || !rducks_rc_write_direct_output(desc->child, &child_view, child_row, element, err_msg, err_cap)) {
                UNPROTECT(1);
                if (ok && !err_msg[0]) rducks_format_error_message(err_msg, err_cap, "failed to write DuckDB ARRAY child value");
                return 0;
            }
            UNPROTECT(1);
        }
        return 1;
    }
    if (desc->kind == RDUCKS_KIND_STRUCT) {
        if (TYPEOF(value) != VECSXP) {
            rducks_format_error_message(err_msg, err_cap, "Rducks STRUCT return value must be a list");
            return 0;
        }
        for (size_t i = 0; i < desc->field_count; i++) {
            int ok = 1;
            duckdb_vector child = duckdb_struct_vector_get_child(output->vector, (idx_t)i);
            rducks_rc_direct_vector_view_t child_view;
            SEXP field = PROTECT(rducks_rc_struct_field(value, desc->field_names[i], i, &ok));
            rducks_rc_direct_view_init(&child_view, child);
            if (!ok || !rducks_rc_write_direct_output(desc->field_types[i], &child_view, row, field, err_msg, err_cap)) {
                UNPROTECT(1);
                if (!ok) {
                    rducks_format_error_message(err_msg, err_cap, "Rducks STRUCT return value is missing field %s",
                             desc->field_names[i] ? desc->field_names[i] : "<unnamed>");
                } else if (!err_msg[0]) {
                    rducks_format_error_message(err_msg, err_cap, "failed to write DuckDB STRUCT field %s",
                             desc->field_names[i] ? desc->field_names[i] : "<unnamed>");
                }
                return 0;
            }
            UNPROTECT(1);
        }
        return 1;
    }
    if (desc->kind == RDUCKS_KIND_MAP) {
        int keys_ok = 1;
        int values_ok = 1;
        SEXP keys = PROTECT(rducks_rc_named_field(value, "keys", &keys_ok));
        SEXP values = PROTECT(rducks_rc_named_field(value, "values", &values_ok));
        R_xlen_t len;
        int duplicated = 0;
        idx_t offset = duckdb_list_vector_get_size(output->vector);
        idx_t required = 0;
        duckdb_list_entry *entries = (duckdb_list_entry *)output->data;
        duckdb_vector entry_vector;
        duckdb_vector key_vector;
        duckdb_vector value_vector;
        rducks_rc_direct_vector_view_t key_view;
        rducks_rc_direct_vector_view_t value_view;
        if (!keys_ok || !values_ok) {
            UNPROTECT(2);
            rducks_format_error_message(err_msg, err_cap, "Rducks MAP return value must have keys and values fields");
            return 0;
        }
        len = XLENGTH(keys);
        if (len < 0 || XLENGTH(values) != len || !rducks_rc_idx_add(offset, (idx_t)len, &required)) {
            UNPROTECT(2);
            rducks_format_error_message(err_msg, err_cap, "Rducks MAP keys and values must have equal valid length");
            return 0;
        }
        if (!rducks_rc_any_duplicated(keys, &duplicated)) {
            UNPROTECT(2);
            rducks_format_error_message(err_msg, err_cap, "failed to validate Rducks MAP keys");
            return 0;
        }
        if (duplicated) {
            UNPROTECT(2);
            rducks_format_error_message(err_msg, err_cap, "Rducks MAP keys must be unique");
            return 0;
        }
        if (duckdb_list_vector_reserve(output->vector, required) == DuckDBError) {
            UNPROTECT(2);
            rducks_format_error_message(err_msg, err_cap, "failed to reserve DuckDB MAP child storage");
            return 0;
        }
        entry_vector = duckdb_list_vector_get_child(output->vector);
        key_vector = duckdb_struct_vector_get_child(entry_vector, 0);
        value_vector = duckdb_struct_vector_get_child(entry_vector, 1);
        rducks_rc_direct_view_init(&key_view, key_vector);
        rducks_rc_direct_view_init(&value_view, value_vector);
        for (R_xlen_t j = 0; j < len; j++) {
            int key_ok = 1;
            int value_ok = 1;
            SEXP key = PROTECT(rducks_rc_vector_value_at(keys, (idx_t)j, &key_ok));
            SEXP item = PROTECT(rducks_rc_vector_value_at(values, (idx_t)j, &value_ok));
            idx_t child_row = 0;
            if (key_ok && rducks_rc_value_is_null_for_output(desc->key, key)) {
                UNPROTECT(4);
                rducks_format_error_message(err_msg, err_cap, "Rducks MAP keys must not be NULL");
                return 0;
            }
            if (!rducks_rc_idx_add(offset, (idx_t)j, &child_row) || !key_ok || !value_ok ||
                !rducks_rc_write_direct_output(desc->key, &key_view, child_row, key, err_msg, err_cap) ||
                !rducks_rc_write_direct_output(desc->value, &value_view, child_row, item, err_msg, err_cap)) {
                UNPROTECT(4);
                if (!err_msg[0]) rducks_format_error_message(err_msg, err_cap, "failed to write DuckDB MAP entry");
                return 0;
            }
            UNPROTECT(2);
        }
        if (duckdb_list_vector_set_size(output->vector, required) == DuckDBError) {
            UNPROTECT(2);
            rducks_format_error_message(err_msg, err_cap, "failed to commit DuckDB MAP child storage");
            return 0;
        }
        entries[row].offset = offset;
        entries[row].length = (uint64_t)len;
        UNPROTECT(2);
        return 1;
    }
    if (desc->kind == RDUCKS_KIND_UNION) {
        int tag_ok = 1;
        int value_ok = 1;
        SEXP tag_value = PROTECT(rducks_rc_named_field(value, "tag", &tag_ok));
        SEXP payload = PROTECT(rducks_rc_named_field(value, "value", &value_ok));
        if (!tag_ok || !value_ok || TYPEOF(tag_value) != STRSXP || XLENGTH(tag_value) < 1 || STRING_ELT(tag_value, 0) == NA_STRING) {
            UNPROTECT(2);
            rducks_format_error_message(err_msg, err_cap, "Rducks UNION return value must have tag and value fields");
            return 0;
        }
        const char *tag_text = CHAR(STRING_ELT(tag_value, 0));
        size_t tag_index = desc->field_count;
        (void)rducks_type_desc_find_field_index(desc, tag_text, &tag_index);
        if (tag_index >= desc->field_count || tag_index > 255U) {
            UNPROTECT(2);
            rducks_format_error_message(err_msg, err_cap, "Rducks UNION tag is outside declared members");
            return 0;
        }
        /* See the UNION input path: DuckDB stores UNION vectors as STRUCT
         * vectors with a tag child followed by one child per member.
         */
        duckdb_vector tag_vector = duckdb_struct_vector_get_child(output->vector, 0);
        rducks_rc_direct_vector_view_t tag_view;
        rducks_rc_direct_view_init(&tag_view, tag_vector);
        duckdb_vector selected_vector = duckdb_struct_vector_get_child(output->vector, (idx_t)tag_index + 1U);
        rducks_rc_direct_vector_view_t selected_view;
        rducks_rc_direct_view_init(&selected_view, selected_vector);
        if (!rducks_rc_write_direct_output(desc->field_types[tag_index], &selected_view, row, payload, err_msg, err_cap)) {
            UNPROTECT(2);
            if (!err_msg[0]) rducks_format_error_message(err_msg, err_cap, "failed to write DuckDB UNION member");
            return 0;
        }
        for (size_t i = 0; i < desc->field_count; i++) {
            if (i == tag_index) continue;
            duckdb_vector member_vector = duckdb_struct_vector_get_child(output->vector, (idx_t)i + 1U);
            rducks_rc_direct_vector_view_t member_view;
            rducks_rc_direct_view_init(&member_view, member_vector);
            if (!rducks_rc_write_null_direct_output(desc->field_types[i], &member_view, row, err_msg, err_cap)) {
                UNPROTECT(2);
                if (!err_msg[0]) rducks_format_error_message(err_msg, err_cap, "failed to write DuckDB UNION inactive member");
                return 0;
            }
        }
        rducks_rc_output_set_valid_if_needed(&tag_view, row);
        ((uint8_t *)tag_view.data)[row] = (uint8_t)tag_index;
        UNPROTECT(2);
        return 1;
    }
    if (desc->kind == RDUCKS_KIND_ENUM) {
        uint32_t index = 0;
        if (!rducks_rc_enum_value_index(desc, value, &index, err_msg, err_cap)) {
            return 0;
        }
        if (!rducks_rc_enum_index_to_data(desc, output->data, row, index)) {
            rducks_format_error_message(err_msg, err_cap, "Rducks enum storage type is unsupported");
            return 0;
        }
        return 1;
    }
    if (desc->kind == RDUCKS_KIND_DECIMAL) {
        uint8_t bytes[16];
        int storage_width = rducks_rc_decimal_storage_width(desc);
        if (!rducks_rc_decimal_storage_string_to_le_bytes(value, storage_width, desc->decimal_scale, bytes, err_msg, err_cap)) {
            return 0;
        }
        if (storage_width == 2) {
            uint16_t u = (uint16_t)(bytes[0] | ((uint16_t)bytes[1] << 8));
            int16_t v;
            memcpy(&v, &u, sizeof(v));
            ((int16_t *)output->data)[row] = v;
        } else if (storage_width == 4) {
            uint32_t u = 0;
            for (int i = 3; i >= 0; i--) u = (u << 8) | (uint32_t)bytes[i];
            int32_t v;
            memcpy(&v, &u, sizeof(v));
            ((int32_t *)output->data)[row] = v;
        } else if (storage_width == 8) {
            uint64_t u = rducks_rc_le_bytes_to_u64(bytes);
            int64_t v;
            memcpy(&v, &u, sizeof(v));
            ((int64_t *)output->data)[row] = v;
        } else {
            rducks_rc_le_bytes_to_hugeint(bytes, &((duckdb_hugeint *)output->data)[row]);
        }
        return 1;
    }
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
    case RDUCKS_TYPE_I64: {
        uint8_t bytes[8];
        if (!rducks_rc_decimal_string_sexp_to_le_bytes(value, 8, 1, bytes, err_msg, err_cap)) return 0;
        uint64_t u = rducks_rc_le_bytes_to_u64(bytes);
        int64_t v;
        memcpy(&v, &u, sizeof(v));
        ((int64_t *)output->data)[row] = v;
        return 1;
    }
    case RDUCKS_TYPE_U64: {
        uint8_t bytes[8];
        if (!rducks_rc_decimal_string_sexp_to_le_bytes(value, 8, 0, bytes, err_msg, err_cap)) return 0;
        ((uint64_t *)output->data)[row] = rducks_rc_le_bytes_to_u64(bytes);
        return 1;
    }
    case RDUCKS_TYPE_F32:
        ((float *)output->data)[row] = (float)Rf_asReal(value);
        return 1;
    case RDUCKS_TYPE_F64:
        ((double *)output->data)[row] = Rf_asReal(value);
        return 1;
    case RDUCKS_TYPE_VARCHAR: {
        if (TYPEOF(value) != STRSXP || XLENGTH(value) < 1) {
            rducks_format_error_message(err_msg, err_cap, "Rducks RC VARCHAR output is not a character scalar");
            return 0;
        }
        SEXP ch = STRING_ELT(value, 0);
        const char *ptr = Rf_translateCharUTF8(ch);
        duckdb_vector_assign_string_element_len(output->vector, row, ptr, (idx_t)strlen(ptr));
        return 1;
    }
    case RDUCKS_TYPE_BLOB:
    case RDUCKS_TYPE_GEOMETRY:
        if (TYPEOF(value) != RAWSXP) {
            rducks_format_error_message(err_msg, err_cap, "Rducks RC binary output is not a raw vector");
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
    case RDUCKS_TYPE_HUGEINT: {
        uint8_t bytes[16];
        if (!rducks_rc_decimal_string_sexp_to_le_bytes(value, 16, 1, bytes, err_msg, err_cap)) return 0;
        rducks_rc_le_bytes_to_hugeint(bytes, &((duckdb_hugeint *)output->data)[row]);
        return 1;
    }
    case RDUCKS_TYPE_UHUGEINT: {
        uint8_t bytes[16];
        if (!rducks_rc_decimal_string_sexp_to_le_bytes(value, 16, 0, bytes, err_msg, err_cap)) return 0;
        rducks_rc_le_bytes_to_uhugeint(bytes, &((duckdb_uhugeint *)output->data)[row]);
        return 1;
    }
    case RDUCKS_TYPE_UUID: {
        duckdb_hugeint uuid;
        if (!rducks_rc_parse_uuid_string(value, &uuid, err_msg, err_cap)) return 0;
        ((duckdb_hugeint *)output->data)[row] = uuid;
        return 1;
    }
    case RDUCKS_TYPE_INTERVAL: {
        duckdb_interval interval;
        if (!rducks_rc_interval_from_object(value, &interval, err_msg, err_cap)) return 0;
        ((duckdb_interval *)output->data)[row] = interval;
        return 1;
    }
    case RDUCKS_TYPE_BIT: {
        char *payload = NULL;
        idx_t len = 0;
        if (!rducks_rc_payload_from_bits(value, &payload, &len, err_msg, err_cap)) return 0;
        duckdb_vector_assign_string_element_len(output->vector, row, payload, len);
        return 1;
    }
    default:
        rducks_format_error_message(err_msg, err_cap, "Rducks RC direct output unsupported type");
        return 0;
    }
}

static int rducks_rc_direct_scalar_eval_on_r_thread(rducks_r_scalar_meta_t *meta,
                                                    rducks_rc_direct_scalar_frame_t *frame,
                                                    char *err_msg, size_t err_cap) {
    SEXP bundle = meta->fun;
    SEXP fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_FUN);
    SEXP return_type = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_RETURN_TYPE);
    SEXP check_return_fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_CHECK_RETURN);
    rducks_rc_direct_vector_view_t *inputs = frame->inputs;
    rducks_rc_direct_vector_view_t *output_view = &frame->output;

    /* Main-R-thread phase: materialize R arguments, call the R function,
     * validate R returns, and write checked SEXP results back to the borrowed
     * DuckDB output vector before the callback returns.
     */
    for (idx_t row = 0; row < frame->n; row++) {
        int has_null = 0;
        for (size_t col = 0; col < meta->arity; col++) {
            if (!rducks_rc_direct_view_valid_at(&inputs[col], row)) {
                has_null = 1;
                break;
            }
        }
        if (meta->null_handling == RDUCKS_NULL_DEFAULT && has_null) {
            if (!rducks_rc_write_null_direct_output(meta->return_desc, output_view, row, err_msg, err_cap)) return 0;
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
        if (r_err) {
            UNPROTECT(2); /* value, args */
            if (meta->exception_handling == RDUCKS_EXCEPTION_RETURN_NULL) {
                if (!rducks_rc_write_null_direct_output(meta->return_desc, output_view, row, err_msg, err_cap)) return 0;
                continue;
            }
            rducks_format_error_message(err_msg, err_cap, "Rducks RC R function error");
            return 0;
        }

        r_err = 0;
        SEXP checked = PROTECT(rducks_rc_check_return(check_return_fun, return_type, value, &r_err));
        if (r_err) {
            UNPROTECT(3); /* checked, value, args */
            rducks_format_error_message(err_msg, err_cap, "Rducks RC return validation or marshal error");
            return 0;
        }
        if (!rducks_rc_write_direct_output(meta->return_desc, output_view, row, checked, err_msg, err_cap)) {
            UNPROTECT(3); /* checked, value, args */
            return 0;
        }
        UNPROTECT(3); /* checked, value, args */
    }
    return 1;
}

static int rducks_rc_direct_scalar_execute(rducks_r_scalar_meta_t *meta, duckdb_data_chunk input, duckdb_vector output,
                                           char *err_msg, size_t err_cap) {
    rducks_rc_direct_scalar_frame_t frame;
    int ok = 0;
    if (!rducks_rc_direct_scalar_snapshot_views(meta, input, output, &frame, err_msg, err_cap)) {
        return 0;
    }
    ok = rducks_rc_direct_scalar_eval_on_r_thread(meta, &frame, err_msg, err_cap);
    rducks_rc_direct_scalar_frame_cleanup(&frame);
    return ok;
}

static SEXP rducks_rc_vectorized_prepare_inputs_on_r_thread(rducks_r_scalar_meta_t *meta,
                                                            duckdb_data_chunk input,
                                                            idx_t n,
                                                            int *protect_count,
                                                            char *err_msg, size_t err_cap) {
    /* Main-R-thread phase for the current vectorized direct path. It
     * materializes borrowed DuckDB vectors into R objects. A later async path
     * must replace this with an owned, non-SEXP snapshot before crossing
     * threads.
     */
    return rducks_rc_direct_prepare_inputs(meta, input, n, protect_count, err_msg, err_cap);
}

static SEXP rducks_rc_vectorized_eval_on_r_thread(SEXP eval_rows_fun, SEXP fun,
                                                  SEXP arg_types, SEXP return_type,
                                                  SEXP prepared,
                                                  SEXP null_handling_sexp,
                                                  SEXP exception_handling_sexp,
                                                  int *protect_count, int *r_err) {
    SEXP results = PROTECT(rducks_rc_call_vectorized_eval(eval_rows_fun, fun, arg_types, return_type,
                                                         prepared, null_handling_sexp,
                                                         exception_handling_sexp, r_err));
    (*protect_count)++;
    return results;
}

static int rducks_rc_vectorized_writeback_from_sexp_on_r_thread(rducks_r_scalar_meta_t *meta,
                                                                SEXP results,
                                                                duckdb_vector output,
                                                                idx_t n,
                                                                char *err_msg, size_t err_cap) {
    /* Main-R-thread writeback for current R callback results. This is not the
     * later worker-safe result phase; that requires owned non-SEXP result
     * payloads before writing DuckDB output off the R thread.
     */
    return rducks_rc_write_direct_results(meta, results, output, n, err_msg, err_cap);
}

static int rducks_rc_vectorized_execute_impl(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                             duckdb_data_chunk input, duckdb_vector output,
                                             char *err_msg, size_t err_cap) {
    (void)runtime;
    idx_t n;
    int protect_count = 0;
    int r_err = 0;
    SEXP bundle;
    SEXP fun;
    SEXP arg_types;
    SEXP return_type;
    SEXP eval_rows_fun;
    SEXP prepared;
    SEXP null_handling_sexp;
    SEXP exception_handling_sexp;
    SEXP results;

    if (!meta || !meta->fun || meta->fun == R_NilValue) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC vectorized metadata missing");
        return 0;
    }
    if (!rducks_rc_direct_supported(meta)) {
        rducks_format_error_message(err_msg, err_cap, "direct marshalling is not implemented for this UDF signature");
        return 0;
    }
    bundle = meta->fun;
    if (!rducks_rc_bundle_valid(bundle)) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC vectorized metadata bundle is invalid");
        return 0;
    }

    rducks_udf_record_evaluator(meta, duckdb_data_chunk_get_size(input));
    n = duckdb_data_chunk_get_size(input);
    fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_FUN);
    arg_types = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_ARG_TYPES);
    return_type = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_RETURN_TYPE);
    eval_rows_fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_EVAL_ROWS);

    prepared = rducks_rc_vectorized_prepare_inputs_on_r_thread(meta, input, n, &protect_count, err_msg, err_cap);
    if (prepared == R_NilValue) goto fail_vectorized;

    null_handling_sexp = PROTECT(rducks_rc_null_handling_sexp(meta->null_handling));
    protect_count++;
    exception_handling_sexp = PROTECT(rducks_rc_exception_handling_sexp(meta->exception_handling));
    protect_count++;
    results = rducks_rc_vectorized_eval_on_r_thread(eval_rows_fun, fun, arg_types, return_type, prepared,
                                                    null_handling_sexp, exception_handling_sexp,
                                                    &protect_count, &r_err);
    if (r_err) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC vectorized R function or marshal error");
        goto fail_vectorized;
    }
    if (!rducks_rc_vectorized_writeback_from_sexp_on_r_thread(meta, results, output, n, err_msg, err_cap)) {
        if (!err_msg[0]) rducks_format_error_message(err_msg, err_cap, "Rducks RC vectorized result writeback failed");
        goto fail_vectorized;
    }

    UNPROTECT(protect_count);
    return 1;

fail_vectorized:
    UNPROTECT(protect_count);
    return 0;
}

/* Current recorded-main-R-thread direct dispatcher. This does not rule
 * out a later worker-safe native backend; it means this direct-vector
 * implementation is only legal on the calling R thread because it may call R
 * and touch SEXPs. Concurrent
 * backends must route through a transport boundary and write DuckDB output from
 * owned non-SEXP result memory, or use a pure-native evaluator with no R calls.
 */
static int rducks_rc_scalar_execute_impl(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                         duckdb_data_chunk input, duckdb_vector output,
                                         char *err_msg, size_t err_cap) {
    if (!meta || !meta->fun || meta->fun == R_NilValue) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC scalar metadata missing");
        return 0;
    }
    rducks_udf_record_evaluator(meta, duckdb_data_chunk_get_size(input));
    if (!rducks_rc_direct_supported(meta)) {
        rducks_format_error_message(err_msg, err_cap, "direct marshalling is not implemented for this UDF signature");
        return 0;
    }
    return rducks_rc_direct_scalar_execute(meta, input, output, err_msg, err_cap);
}

typedef int (*rducks_rc_execute_fn_t)(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                       duckdb_data_chunk input, duckdb_vector output,
                                       char *err_msg, size_t err_cap);

typedef struct rducks_rc_execute_context {
    rducks_runtime_entry_t *runtime;
    rducks_r_scalar_meta_t *meta;
    duckdb_data_chunk input;
    duckdb_vector output;
    char *err_msg;
    size_t err_cap;
    const char *default_error;
    rducks_rc_execute_fn_t execute;
    int ok;
    int jumped;
} rducks_rc_execute_context_t;

static void rducks_rc_set_default_error(rducks_rc_execute_context_t *ctx) {
    if (ctx && ctx->err_msg && ctx->err_cap > 0U && !ctx->err_msg[0] && ctx->default_error) {
        rducks_format_error_message(ctx->err_msg, ctx->err_cap, "%s", ctx->default_error);
    }
}

static SEXP rducks_rc_execute_unwind_body(void *data) {
    rducks_rc_execute_context_t *ctx = (rducks_rc_execute_context_t *)data;
    ctx->ok = ctx->execute(ctx->runtime, ctx->meta, ctx->input, ctx->output,
                           ctx->err_msg, ctx->err_cap);
    return R_NilValue;
}

static void rducks_rc_execute_unwind_cleanup(void *data, Rboolean jump) {
    rducks_rc_execute_context_t *ctx = (rducks_rc_execute_context_t *)data;
    if (!ctx) return;
    if (jump) {
        ctx->jumped = 1;
        ctx->ok = 0;
        rducks_rc_set_default_error(ctx);
    }
}

static SEXP rducks_rc_execute_try_body(void *data) {
    rducks_rc_execute_context_t *ctx = (rducks_rc_execute_context_t *)data;
    return R_UnwindProtect(rducks_rc_execute_unwind_body, ctx,
                           rducks_rc_execute_unwind_cleanup, ctx,
                           NULL);
}

static SEXP rducks_rc_execute_error_handler(SEXP condition, void *data) {
    (void)condition;
    rducks_rc_execute_context_t *ctx = (rducks_rc_execute_context_t *)data;
    if (ctx) {
        ctx->ok = 0;
        rducks_rc_set_default_error(ctx);
    }
    return R_NilValue;
}

/* Direct callbacks run from inside DuckDB scalar UDF callbacks, not
 * from an R prompt. Do not install a fresh top-level context here.
 * R_tryCatchError() catches R allocation/marshalling errors that would otherwise
 * longjmp across DuckDB, while R_UnwindProtect() marks abnormal unwinds and is
 * the place to add deterministic cleanup if later direct sections
 * acquire native malloc/DuckDB handles. The current impl bodies only
 * borrow callback vectors and use R PROTECT/UNPROTECT-managed SEXPs.
 */
static int rducks_rc_execute_with_error_boundary(rducks_rc_execute_context_t *ctx,
                                                 rducks_rc_execute_fn_t execute,
                                                 const char *default_error) {
    ctx->ok = 0;
    ctx->jumped = 0;
    ctx->execute = execute;
    ctx->default_error = default_error;
    if (ctx->err_msg && ctx->err_cap > 0U) ctx->err_msg[0] = '\0';
    (void)R_tryCatchError(rducks_rc_execute_try_body, ctx,
                          rducks_rc_execute_error_handler, ctx);
    return ctx->ok;
}

static int rducks_rc_scalar_execute(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                    duckdb_data_chunk input, duckdb_vector output,
                                    char *err_msg, size_t err_cap) {
    rducks_rc_execute_context_t ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.runtime = runtime;
    ctx.meta = meta;
    ctx.input = input;
    ctx.output = output;
    ctx.err_msg = err_msg;
    ctx.err_cap = err_cap;
    return rducks_rc_execute_with_error_boundary(&ctx, rducks_rc_scalar_execute_impl,
                                                 "Rducks RC scalar R function or marshal error");
}

static int rducks_rc_vectorized_execute(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                        duckdb_data_chunk input, duckdb_vector output,
                                        char *err_msg, size_t err_cap) {
    rducks_rc_execute_context_t ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.runtime = runtime;
    ctx.meta = meta;
    ctx.input = input;
    ctx.output = output;
    ctx.err_msg = err_msg;
    ctx.err_cap = err_cap;
    return rducks_rc_execute_with_error_boundary(&ctx, rducks_rc_vectorized_execute_impl,
                                                 "Rducks RC vectorized R function or marshal error");
}

static int rducks_rc_owned_result_chunk_supported(rducks_r_scalar_meta_t *meta) {
    return meta && (meta->eval_mode == RDUCKS_EVAL_RC || meta->eval_mode == RDUCKS_EVAL_RCV) &&
           rducks_rc_direct_supported(meta);
}

static int rducks_rc_owned_result_queue_supported(rducks_r_scalar_meta_t *meta) {
    return rducks_rc_owned_result_chunk_supported(meta);
}

static duckdb_data_chunk rducks_rc_owned_result_chunk_new(rducks_r_scalar_meta_t *meta,
                                                          idx_t n,
                                                          char *err_msg, size_t err_cap) {
    duckdb_logical_type type;
    duckdb_data_chunk chunk;
    if (!meta || !meta->return_desc) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC owned result chunk metadata missing");
        return NULL;
    }
    type = rducks_create_logical_type_for_desc(meta->return_desc);
    if (!type) {
        rducks_format_error_message(err_msg, err_cap, "failed to allocate Rducks RC owned result logical type");
        return NULL;
    }
    chunk = duckdb_create_data_chunk(&type, 1);
    duckdb_destroy_logical_type(&type);
    if (!chunk) {
        rducks_format_error_message(err_msg, err_cap, "failed to allocate Rducks RC owned result data chunk");
        return NULL;
    }
    duckdb_data_chunk_set_size(chunk, n);
    return chunk;
}

static int rducks_rc_owned_result_chunk_writeback(duckdb_data_chunk chunk,
                                                  duckdb_vector output,
                                                  char *err_msg, size_t err_cap) {
    duckdb_selection_vector sel = NULL;
    duckdb_vector src;
    sel_t *sel_data;
    idx_t n;
    if (!chunk || !output) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC owned result chunk writeback is missing state");
        return 0;
    }
    n = duckdb_data_chunk_get_size(chunk);
    if (n == 0) return 1;
    if (n > (idx_t)UINT32_MAX) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC owned result chunk is too large to write back");
        return 0;
    }
    src = duckdb_data_chunk_get_vector(chunk, 0);
    if (!src) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC owned result chunk has no result vector");
        return 0;
    }
    sel = duckdb_create_selection_vector(n);
    if (!sel) {
        rducks_format_error_message(err_msg, err_cap, "failed to allocate Rducks RC owned result writeback selection vector");
        return 0;
    }
    sel_data = duckdb_selection_vector_get_data_ptr(sel);
    if (!sel_data) {
        duckdb_destroy_selection_vector(sel);
        rducks_format_error_message(err_msg, err_cap, "failed to access Rducks RC owned result writeback selection vector");
        return 0;
    }
    for (idx_t row = 0; row < n; row++) sel_data[row] = (sel_t)row;
    duckdb_vector_copy_sel(src, output, sel, n, 0, 0);
    duckdb_destroy_selection_vector(sel);
    return 1;
}

static int rducks_rc_scalar_execute_to_owned_chunk(rducks_runtime_entry_t *runtime,
                                                   rducks_r_scalar_meta_t *meta,
                                                   duckdb_data_chunk input,
                                                   duckdb_vector output,
                                                   duckdb_data_chunk *chunk_out,
                                                   char *err_msg, size_t err_cap) {
    duckdb_data_chunk chunk;
    duckdb_vector chunk_output;
    int ok;
    (void)output;
    if (chunk_out) *chunk_out = NULL;
    if (!chunk_out || !rducks_rc_owned_result_chunk_supported(meta)) {
        rducks_format_error_message(err_msg, err_cap, "Rducks RC owned result chunk is not implemented for this return type");
        return 0;
    }
    chunk = rducks_rc_owned_result_chunk_new(meta, duckdb_data_chunk_get_size(input), err_msg, err_cap);
    if (!chunk) return 0;
    chunk_output = duckdb_data_chunk_get_vector(chunk, 0);
    if (!chunk_output) {
        duckdb_destroy_data_chunk(&chunk);
        rducks_format_error_message(err_msg, err_cap, "Rducks RC owned result chunk has no output vector");
        return 0;
    }
    if (meta->eval_mode == RDUCKS_EVAL_RCV) {
        ok = rducks_rc_vectorized_execute(runtime, meta, input, chunk_output, err_msg, err_cap);
    } else {
        ok = rducks_rc_scalar_execute(runtime, meta, input, chunk_output, err_msg, err_cap);
    }
    if (!ok) {
        duckdb_destroy_data_chunk(&chunk);
        return 0;
    }
    rducks_udf_record_direct_owned_result_chunk(meta);
    *chunk_out = chunk;
    return 1;
}
