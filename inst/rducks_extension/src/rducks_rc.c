/* Included by ../rducks_extension.c.
 *
 * RC scalar execution is intentionally a calling-R-thread implementation today.
 * This file mixes DuckDB vector access with R API calls because
 * rducks_r_scalar_udf() rejects non-calling-thread execution before entering the
 * evaluator. Do not treat these helpers as worker-thread safe.
 *
 * Any future concurrent UDF implementation must split this path into explicit
 * phases:
 *   1. worker-safe DuckDB/vector snapshot or result import code with no R API;
 *   2. main-R-thread evaluation and R/nanoarrow external-pointer handling;
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


static int rducks_rc_direct_type_supported(const rducks_type_desc_t *desc) {
    if (!desc) return 0;
    if (desc->kind == RDUCKS_KIND_DECIMAL) return 1;
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

static void rducks_rc_limbs_mul_add(uint32_t *limbs, size_t *nlimbs, uint32_t multiplier, uint32_t addend) {
    uint64_t carry = addend;
    for (size_t i = 0; i < *nlimbs; i++) {
        uint64_t value = (uint64_t)limbs[i] * (uint64_t)multiplier + carry;
        limbs[i] = (uint32_t)(value % RDUCKS_RC_DEC_BASE);
        carry = value / RDUCKS_RC_DEC_BASE;
    }
    while (carry) {
        limbs[*nlimbs] = (uint32_t)(carry % RDUCKS_RC_DEC_BASE);
        carry /= RDUCKS_RC_DEC_BASE;
        (*nlimbs)++;
    }
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
        rducks_rc_limbs_mul_add(limbs, &nlimbs, 256U, (uint32_t)bytes[i - 1U]);
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
            snprintf(err_msg, err_cap, "expected a decimal integer string");
            return 0;
        }
        work[i] = (unsigned char)(digits[i] - '0');
    }
    size_t ndigits = len;
    int byte_pos = 0;
    while (ndigits > 0) {
        if (byte_pos >= width) {
            snprintf(err_msg, err_cap, "integer value does not fit in DuckDB storage");
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
        snprintf(err_msg, err_cap, "unsigned integer value is negative");
        return 0;
    }
    if (!rducks_rc_decimal_abs_to_unsigned_bytes(s, len, width, out, err_msg, err_cap)) return 0;
    if (signed_value && width > 0) {
        if (!neg) {
            if (out[width - 1] >= 128U) {
                snprintf(err_msg, err_cap, "signed integer value does not fit in DuckDB storage");
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
                snprintf(err_msg, err_cap, "signed integer value does not fit in DuckDB storage");
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
        snprintf(err_msg, err_cap, "expected a non-missing decimal integer string");
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

static SEXP rducks_rc_make_classed_string(const char *value, const char *class_name) {
    return rducks_rc_make_classed_string_len(value, strlen(value), class_name);
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
        snprintf(err_msg, err_cap, "Rducks RC DECIMAL output is not a rducks_decimal object");
        return 0;
    }
    SEXP values = VECTOR_ELT(value, 0);
    if (TYPEOF(values) != STRSXP || XLENGTH(values) < 1 || STRING_ELT(values, 0) == NA_STRING) {
        snprintf(err_msg, err_cap, "Rducks RC DECIMAL output is missing");
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
            snprintf(err_msg, err_cap, "DECIMAL values must be fixed-point decimal strings");
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
        snprintf(err_msg, err_cap, "Rducks RC UUID output is not a non-missing UUID string");
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
            snprintf(err_msg, err_cap, "invalid UUID value");
            return 0;
        }
        if (count >= 32) {
            snprintf(err_msg, err_cap, "invalid UUID value");
            return 0;
        }
        if (count < 16) upper = (upper << 4) | (uint64_t)v;
        else lower = (lower << 4) | (uint64_t)v;
        count++;
    }
    if (count != 32) {
        snprintf(err_msg, err_cap, "invalid UUID value");
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
        snprintf(err_msg, err_cap, "Rducks RC INTERVAL output is not a rducks_interval object");
        return 0;
    }
    SEXP months = VECTOR_ELT(value, 0);
    SEXP days = VECTOR_ELT(value, 1);
    SEXP micros = VECTOR_ELT(value, 2);
    out->months = (int32_t)Rf_asInteger(months);
    out->days = (int32_t)Rf_asInteger(days);
    if (out->months == NA_INTEGER || out->days == NA_INTEGER) {
        snprintf(err_msg, err_cap, "Rducks RC INTERVAL output is missing");
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
        snprintf(err_msg, err_cap, "Rducks RC BIT output is not a rducks_bits object");
        return 0;
    }
    SEXP data = VECTOR_ELT(value, 0);
    int bit_length = Rf_asInteger(VECTOR_ELT(value, 1));
    if (TYPEOF(data) != RAWSXP || bit_length <= 0 || (R_xlen_t)bit_length > XLENGTH(data) * 8) {
        snprintf(err_msg, err_cap, "Rducks RC BIT output has invalid storage");
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

static int rducks_rc_value_is_null_for_output(const rducks_type_desc_t *desc, SEXP value) {
    if (value == R_NilValue) return 1;
    if (desc->kind == RDUCKS_KIND_DECIMAL) {
        if (TYPEOF(value) != VECSXP || XLENGTH(value) < 1) return 0;
        SEXP values = VECTOR_ELT(value, 0);
        return TYPEOF(values) == STRSXP && XLENGTH(values) > 0 && STRING_ELT(values, 0) == NA_STRING;
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
    if (desc->scalar == RDUCKS_TYPE_BLOB || desc->scalar == RDUCKS_TYPE_BIT) return 0;
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

/* RC fallback phases use the R-side Arrow prepare/result helpers while keeping
 * row evaluation in C for eval_mode = "RC" semantics. This path remains
 * R-thread-only because it creates nanoarrow external pointers and calls R
 * helpers. It is intentionally isolated from the direct DuckDB vector path so a
 * future concurrent backend can reuse the prepared row engine with an owned
 * transport such as Arrow IPC instead of borrowed DuckDB vectors.
 */
static SEXP rducks_rc_eval_arrow_xptr_on_r_thread(rducks_r_scalar_meta_t *meta,
                                                  SEXP input_array_xptr, SEXP input_schema_xptr,
                                                  SEXP output_schema_xptr, idx_t n,
                                                  int *protect_count, char *err_msg, size_t err_cap) {
    int r_err = 0;
    SEXP bundle;
    SEXP fun;
    SEXP arg_types;
    SEXP return_type;
    SEXP prepare_inputs_fun;
    SEXP check_return_fun;
    SEXP result_array_fun;
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
        return R_NilValue;
    }
    bundle = meta->fun;
    if (!rducks_rc_bundle_valid(bundle)) {
        snprintf(err_msg, err_cap, "Rducks RC scalar metadata bundle is invalid");
        return R_NilValue;
    }

    fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_FUN);
    arg_types = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_ARG_TYPES);
    return_type = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_RETURN_TYPE);
    prepare_inputs_fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_PREPARE_INPUTS);
    check_return_fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_CHECK_RETURN);
    result_array_fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_RESULT_ARRAY);

    n_sexp = PROTECT(Rf_ScalarReal((double)n));
    (*protect_count)++;
    prep_call = PROTECT(Rf_lang5(prepare_inputs_fun, arg_types, input_array_xptr, input_schema_xptr, n_sexp));
    (*protect_count)++;
    prepared = PROTECT(R_tryEvalSilent(prep_call, R_GlobalEnv, &r_err));
    (*protect_count)++;
    if (r_err || TYPEOF(prepared) != VECSXP || XLENGTH(prepared) < 3) {
        snprintf(err_msg, err_cap, "Rducks RC input preparation failed");
        return R_NilValue;
    }
    columns = VECTOR_ELT(prepared, 0);
    nulls = VECTOR_ELT(prepared, 1);
    top_level_null = VECTOR_ELT(prepared, 2);
    if (TYPEOF(columns) != VECSXP || TYPEOF(nulls) != VECSXP || TYPEOF(top_level_null) != LGLSXP) {
        snprintf(err_msg, err_cap, "Rducks RC input preparation returned invalid metadata");
        return R_NilValue;
    }

    results = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)n));
    (*protect_count)++;
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
                return R_NilValue;
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
            return R_NilValue;
        }

        r_err = 0;
        SEXP checked = PROTECT(rducks_rc_check_return(check_return_fun, return_type, value, &r_err));
        UNPROTECT(1); /* value */
        if (r_err) {
            UNPROTECT(1); /* checked */
            snprintf(err_msg, err_cap, "Rducks RC return validation or marshal error");
            return R_NilValue;
        }
        SET_VECTOR_ELT(results, (R_xlen_t)row, checked);
        UNPROTECT(1); /* checked */
    }

    result_call = PROTECT(Rf_lang5(result_array_fun, return_type, results, output_schema_xptr, n_sexp));
    (*protect_count)++;
    r_err = 0;
    result_array = PROTECT(R_tryEvalSilent(result_call, R_GlobalEnv, &r_err));
    (*protect_count)++;
    if (r_err) {
        snprintf(err_msg, err_cap, "Rducks RC Arrow result construction failed");
        return R_NilValue;
    }
    return result_array;
}

static int rducks_rc_arrow_scalar_execute_on_r_thread(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                                      duckdb_data_chunk input,
                                                      duckdb_vector output, char *err_msg, size_t err_cap) {
    idx_t n;
    int protect_count = 0;
    SEXP input_schema_xptr;
    SEXP input_array_xptr;
    SEXP output_schema_xptr;
    SEXP result_array;

    if (!meta || !meta->fun || meta->fun == R_NilValue) {
        snprintf(err_msg, err_cap, "Rducks RC scalar metadata missing");
        return 0;
    }

    n = duckdb_data_chunk_get_size(input);
    input_schema_xptr = PROTECT(nanoarrow_schema_owning_xptr());
    protect_count++;
    if (!rducks_fill_input_arrow_schema(runtime, input_schema_xptr, meta, err_msg, err_cap)) goto fail;

    input_array_xptr = PROTECT(nanoarrow_array_owning_xptr());
    protect_count++;
    if (!rducks_fill_input_arrow_array(runtime, input_array_xptr, input, err_msg, err_cap)) goto fail;
    R_SetExternalPtrTag(input_array_xptr, input_schema_xptr);

    output_schema_xptr = PROTECT(nanoarrow_schema_owning_xptr());
    protect_count++;
    if (!rducks_fill_output_arrow_schema(runtime, output_schema_xptr, meta, err_msg, err_cap)) goto fail;

    result_array = rducks_rc_eval_arrow_xptr_on_r_thread(meta, input_array_xptr, input_schema_xptr,
                                                         output_schema_xptr, n, &protect_count, err_msg, err_cap);
    if (result_array == R_NilValue) goto fail;
    if (!rducks_import_arrow_result(runtime, result_array, output_schema_xptr, meta->return_desc, n, output, err_msg, err_cap)) goto fail;

    UNPROTECT(protect_count);
    return 1;

fail:
    UNPROTECT(protect_count);
    return 0;
}

static SEXP rducks_rc_eval_arrow_vectorized_xptr_on_r_thread(rducks_r_scalar_meta_t *meta,
                                                             SEXP input_array_xptr, SEXP input_schema_xptr,
                                                             SEXP output_schema_xptr, idx_t n,
                                                             int *protect_count, char *err_msg, size_t err_cap) {
    int r_err = 0;
    SEXP bundle;
    SEXP fun;
    SEXP arg_types;
    SEXP return_type;
    SEXP prepare_inputs_fun;
    SEXP result_array_fun;
    SEXP eval_rows_fun;
    SEXP n_sexp;
    SEXP prep_call;
    SEXP prepared;
    SEXP null_handling_sexp;
    SEXP exception_handling_sexp;
    SEXP results;
    SEXP result_call;
    SEXP result_array;

    if (!meta || !meta->fun || meta->fun == R_NilValue) {
        snprintf(err_msg, err_cap, "Rducks RC vectorized metadata missing");
        return R_NilValue;
    }
    bundle = meta->fun;
    if (!rducks_rc_bundle_valid(bundle)) {
        snprintf(err_msg, err_cap, "Rducks RC vectorized metadata bundle is invalid");
        return R_NilValue;
    }

    fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_FUN);
    arg_types = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_ARG_TYPES);
    return_type = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_RETURN_TYPE);
    prepare_inputs_fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_PREPARE_INPUTS);
    result_array_fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_RESULT_ARRAY);
    eval_rows_fun = VECTOR_ELT(bundle, RDUCKS_RC_BUNDLE_EVAL_ROWS);

    n_sexp = PROTECT(Rf_ScalarReal((double)n));
    (*protect_count)++;
    prep_call = PROTECT(Rf_lang5(prepare_inputs_fun, arg_types, input_array_xptr, input_schema_xptr, n_sexp));
    (*protect_count)++;
    prepared = PROTECT(R_tryEvalSilent(prep_call, R_GlobalEnv, &r_err));
    (*protect_count)++;
    if (r_err || TYPEOF(prepared) != VECSXP || XLENGTH(prepared) < 3) {
        snprintf(err_msg, err_cap, "Rducks RC vectorized input preparation failed");
        return R_NilValue;
    }

    null_handling_sexp = PROTECT(rducks_rc_null_handling_sexp(meta->null_handling));
    (*protect_count)++;
    exception_handling_sexp = PROTECT(rducks_rc_exception_handling_sexp(meta->exception_handling));
    (*protect_count)++;
    results = PROTECT(rducks_rc_call_vectorized_eval(eval_rows_fun, fun, arg_types, return_type, prepared,
                                                     null_handling_sexp, exception_handling_sexp, &r_err));
    (*protect_count)++;
    if (r_err || TYPEOF(results) != VECSXP || XLENGTH(results) != (R_xlen_t)n) {
        snprintf(err_msg, err_cap, "Rducks RC vectorized R function or marshal error");
        return R_NilValue;
    }

    result_call = PROTECT(Rf_lang5(result_array_fun, return_type, results, output_schema_xptr, n_sexp));
    (*protect_count)++;
    r_err = 0;
    result_array = PROTECT(R_tryEvalSilent(result_call, R_GlobalEnv, &r_err));
    (*protect_count)++;
    if (r_err) {
        snprintf(err_msg, err_cap, "Rducks RC vectorized Arrow result construction failed");
        return R_NilValue;
    }
    return result_array;
}

static int rducks_rc_vectorized_execute(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                        duckdb_data_chunk input, duckdb_vector output,
                                        char *err_msg, size_t err_cap) {
    idx_t n;
    int protect_count = 0;
    SEXP input_schema_xptr;
    SEXP input_array_xptr;
    SEXP output_schema_xptr;
    SEXP result_array;

    if (!meta || !meta->fun || meta->fun == R_NilValue) {
        snprintf(err_msg, err_cap, "Rducks RC vectorized metadata missing");
        return 0;
    }

    rducks_udf_record_evaluator(meta, duckdb_data_chunk_get_size(input));
    n = duckdb_data_chunk_get_size(input);
    input_schema_xptr = PROTECT(nanoarrow_schema_owning_xptr());
    protect_count++;
    if (!rducks_fill_input_arrow_schema(runtime, input_schema_xptr, meta, err_msg, err_cap)) goto fail_vectorized;

    input_array_xptr = PROTECT(nanoarrow_array_owning_xptr());
    protect_count++;
    if (!rducks_fill_input_arrow_array(runtime, input_array_xptr, input, err_msg, err_cap)) goto fail_vectorized;
    R_SetExternalPtrTag(input_array_xptr, input_schema_xptr);

    output_schema_xptr = PROTECT(nanoarrow_schema_owning_xptr());
    protect_count++;
    if (!rducks_fill_output_arrow_schema(runtime, output_schema_xptr, meta, err_msg, err_cap)) goto fail_vectorized;

    result_array = rducks_rc_eval_arrow_vectorized_xptr_on_r_thread(meta, input_array_xptr, input_schema_xptr,
                                                                    output_schema_xptr, n, &protect_count,
                                                                    err_msg, err_cap);
    if (result_array == R_NilValue) goto fail_vectorized;
    if (!rducks_import_arrow_result(runtime, result_array, output_schema_xptr, meta->return_desc, n, output,
                                    err_msg, err_cap)) goto fail_vectorized;

    UNPROTECT(protect_count);
    return 1;

fail_vectorized:
    UNPROTECT(protect_count);
    return 0;
}

/* Current calling-R-thread RC dispatcher. This does not rule out a future
 * threaded RC backend; it means this direct-vector implementation is only legal
 * on the calling R thread because it may call R and touch SEXPs. Concurrent
 * backends must route through a transport boundary and write DuckDB output from
 * owned non-SEXP result memory, or use a pure-native evaluator with no R calls.
 */
static int rducks_rc_scalar_execute(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                    duckdb_data_chunk input, duckdb_vector output,
                                    char *err_msg, size_t err_cap) {
    if (!meta || !meta->fun || meta->fun == R_NilValue) {
        snprintf(err_msg, err_cap, "Rducks RC scalar metadata missing");
        return 0;
    }
    rducks_udf_record_evaluator(meta, duckdb_data_chunk_get_size(input));
    if (rducks_rc_direct_supported(meta)) {
        return rducks_rc_direct_scalar_execute(meta, input, output, err_msg, err_cap);
    }
    return rducks_rc_arrow_scalar_execute_on_r_thread(runtime, meta, input, output, err_msg, err_cap);
}
