/* Included by ../rducks_extension.c. */

#define RDUCKS_TABLE_DEFAULT_CHUNK_SIZE 1024ULL

typedef struct rducks_r_table_meta {
    SEXP fun;
    char *name;
    rducks_runtime_entry_t *runtime;
    idx_t parameter_count;
    idx_t chunk_size;
} rducks_r_table_meta_t;

typedef struct rducks_r_table_bind {
    rducks_r_table_meta_t *meta;
    SEXP result;
    size_t column_count;
    char **column_names;
    rducks_type_desc_t **column_descs;
    duckdb_data_chunk imported_chunk;
    idx_t rows;
    int streaming;
    int cardinality_known;
    int cardinality_exact;
    idx_t cardinality;
    atomic_uint refcount;
} rducks_r_table_bind_t;

typedef struct rducks_r_table_state {
    rducks_r_table_bind_t *bind;
    idx_t pos;
    idx_t projected_count;
    idx_t *projected_columns;
    duckdb_selection_vector sel;
    idx_t sel_capacity;
    duckdb_data_chunk current_chunk;
    idx_t current_rows;
    idx_t current_pos;
    int stream_done;
} rducks_r_table_state_t;

static void rducks_r_table_release_preserved(rducks_runtime_entry_t *runtime, SEXP object) {
    if (!object || object == R_NilValue) return;
    if (rducks_is_main_thread(runtime)) {
        rducks_preserved_release_now(object);
    } else {
        rducks_preserved_release_enqueue(object);
    }
}

static void rducks_r_table_meta_destroy(void *ptr) {
    rducks_r_table_meta_t *meta = (rducks_r_table_meta_t *)ptr;
    if (!meta) return;
    rducks_r_table_release_preserved(meta->runtime, meta->fun);
    meta->fun = R_NilValue;
    free(meta->name);
    free(meta);
}

static void rducks_r_table_close_stream_if_main(rducks_r_table_bind_t *bind) {
    if (!bind || !bind->streaming || bind->result == R_NilValue ||
        !bind->meta || !bind->meta->runtime || !rducks_is_main_thread(bind->meta->runtime)) {
        return;
    }
    rducks_close_table_stream_on_main(bind->result);
}

static void rducks_r_table_bind_retain(rducks_r_table_bind_t *bind) {
    if (!bind) return;
    atomic_fetch_add_explicit(&bind->refcount, 1U, memory_order_relaxed);
}

static void rducks_r_table_bind_free(rducks_r_table_bind_t *bind) {
    rducks_runtime_entry_t *runtime;
    int close_stream_on_release;
    if (!bind) return;
    runtime = bind->meta ? bind->meta->runtime : NULL;
    close_stream_on_release = bind->streaming && bind->result != R_NilValue && runtime && !rducks_is_main_thread(runtime);
    if (close_stream_on_release) {
        rducks_preserved_release_enqueue_table_stream(bind->result);
    } else {
        rducks_r_table_close_stream_if_main(bind);
        rducks_r_table_release_preserved(runtime, bind->result);
    }
    bind->result = R_NilValue;
    if (bind->imported_chunk) duckdb_destroy_data_chunk(&bind->imported_chunk);
    if (bind->column_names) {
        for (size_t i = 0; i < bind->column_count; i++) free(bind->column_names[i]);
    }
    free(bind->column_names);
    if (bind->column_descs) {
        for (size_t i = 0; i < bind->column_count; i++) rducks_type_desc_destroy(bind->column_descs[i]);
    }
    free(bind->column_descs);
    free(bind);
}

static void rducks_r_table_bind_release(rducks_r_table_bind_t *bind) {
    if (!bind) return;
    if (atomic_fetch_sub_explicit(&bind->refcount, 1U, memory_order_acq_rel) == 1U) {
        rducks_r_table_bind_free(bind);
    }
}

static void rducks_r_table_bind_destroy(void *ptr) {
    rducks_r_table_bind_release((rducks_r_table_bind_t *)ptr);
}

static void rducks_r_table_state_destroy(void *ptr) {
    rducks_r_table_state_t *state = (rducks_r_table_state_t *)ptr;
    if (!state) return;
    if (state->current_chunk) duckdb_destroy_data_chunk(&state->current_chunk);
    if (state->sel) duckdb_destroy_selection_vector(state->sel);
    free(state->projected_columns);
    rducks_r_table_bind_release(state->bind);
    state->bind = NULL;
    free(state);
}

static void rducks_r_table_set_r_error(SEXP err_obj, const char *fallback, char *err, size_t err_cap) {
    int r_err = 0;
    if (!err || err_cap == 0) return;
    rducks_format_error_message(err, err_cap, "%s", fallback ? fallback : "Rducks table R function or marshal error");
    const char *cur_error = R_curErrorBuf();
    if (cur_error && cur_error[0]) {
        rducks_format_error_message(err, err_cap, "%s: %s", fallback ? fallback : "Rducks table R function or marshal error", cur_error);
        return;
    }
    if (!err_obj || err_obj == R_NilValue) return;
    if (TYPEOF(err_obj) == STRSXP && XLENGTH(err_obj) > 0 && STRING_ELT(err_obj, 0) != NA_STRING) {
        rducks_format_error_message(err, err_cap, "%s: %s", fallback ? fallback : "Rducks table R function or marshal error",
                 CHAR(STRING_ELT(err_obj, 0)));
        return;
    }
    SEXP call = PROTECT(Rf_lang2(Rf_install("conditionMessage"), err_obj));
    SEXP msg = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, &r_err));
    if (!r_err && TYPEOF(msg) == STRSXP && XLENGTH(msg) > 0 && STRING_ELT(msg, 0) != NA_STRING) {
        rducks_format_error_message(err, err_cap, "%s: %s", fallback ? fallback : "Rducks table R function or marshal error",
                 CHAR(STRING_ELT(msg, 0)));
    }
    UNPROTECT(2);
}

static SEXP rducks_r_table_posixct(double seconds) {
    SEXP out = PROTECT(Rf_ScalarReal(seconds));
    SEXP cls = PROTECT(Rf_allocVector(STRSXP, 2));
    SEXP tzone = PROTECT(Rf_mkString("UTC"));
    SET_STRING_ELT(cls, 0, Rf_mkChar("POSIXct"));
    SET_STRING_ELT(cls, 1, Rf_mkChar("POSIXt"));
    Rf_setAttrib(out, R_ClassSymbol, cls);
    Rf_setAttrib(out, Rf_install("tzone"), tzone);
    UNPROTECT(3);
    return out;
}

static SEXP rducks_r_table_date(double days) {
    SEXP out = PROTECT(Rf_ScalarReal(days));
    SEXP cls = PROTECT(Rf_mkString("Date"));
    Rf_setAttrib(out, R_ClassSymbol, cls);
    UNPROTECT(2);
    return out;
}

static SEXP rducks_r_table_uint64_scalar(uint64_t value) {
    if (value <= (uint64_t)INT32_MAX) return Rf_ScalarInteger((int)value);
    return Rf_ScalarReal((double)value);
}

static SEXP rducks_r_table_bigint_scalar(int64_t value) {
    uint8_t bytes[8];
    uint64_t u;
    memcpy(&u, &value, sizeof(u));
    rducks_rc_u64_to_le_bytes(u, bytes);
    return rducks_rc_make_integer_object_from_le_bytes(bytes, 8, 1, "rducks_bigint");
}

static SEXP rducks_r_table_ubigint_scalar(uint64_t value) {
    uint8_t bytes[8];
    rducks_rc_u64_to_le_bytes(value, bytes);
    return rducks_rc_make_integer_object_from_le_bytes(bytes, 8, 0, "rducks_ubigint");
}

static int rducks_r_table_duckdb_value_to_r(duckdb_value value, SEXP *out, char *err, size_t err_cap);

static int rducks_r_table_duckdb_value_string_to_r(duckdb_value value, SEXP *out, char *err, size_t err_cap) {
    char *text = duckdb_get_varchar(value);
    if (!text) {
        rducks_format_error_message(err, err_cap, "failed to convert DuckDB table argument to character");
        return 0;
    }
    *out = Rf_mkString(text);
    duckdb_free(text);
    return 1;
}

static int rducks_r_table_duckdb_value_blob_to_r(duckdb_value value, SEXP *out, char *err, size_t err_cap) {
    duckdb_blob blob = duckdb_get_blob(value);
    SEXP raw;
    if (blob.size > (idx_t)R_XLEN_T_MAX) {
        if (blob.data) duckdb_free(blob.data);
        rducks_format_error_message(err, err_cap, "DuckDB table BLOB argument is too large for R");
        return 0;
    }
    raw = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)blob.size));
    if (blob.size > 0 && blob.data) memcpy(RAW(raw), blob.data, (size_t)blob.size);
    if (blob.data) duckdb_free(blob.data);
    UNPROTECT(1);
    *out = raw;
    return 1;
}

static int rducks_r_table_duckdb_value_list_to_r(duckdb_value value, SEXP *out, char *err, size_t err_cap) {
    idx_t n = duckdb_get_list_size(value);
    SEXP list;
    if (n > (idx_t)R_XLEN_T_MAX) {
        rducks_format_error_message(err, err_cap, "DuckDB table LIST argument is too large for R");
        return 0;
    }
    list = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)n));
    for (idx_t i = 0; i < n; i++) {
        duckdb_value child = duckdb_get_list_child(value, i);
        SEXP child_r = R_NilValue;
        if (!child) {
            UNPROTECT(1);
            rducks_format_error_message(err, err_cap, "failed to read DuckDB table LIST argument child");
            return 0;
        }
        if (!rducks_r_table_duckdb_value_to_r(child, &child_r, err, err_cap)) {
            duckdb_destroy_value(&child);
            UNPROTECT(1);
            return 0;
        }
        SET_VECTOR_ELT(list, (R_xlen_t)i, child_r);
        duckdb_destroy_value(&child);
    }
    UNPROTECT(1);
    *out = list;
    return 1;
}

static int rducks_r_table_duckdb_value_struct_to_r(duckdb_value value, duckdb_logical_type type,
                                                   SEXP *out, char *err, size_t err_cap) {
    idx_t n = duckdb_struct_type_child_count(type);
    SEXP list;
    SEXP names;
    if (n > (idx_t)R_XLEN_T_MAX) {
        rducks_format_error_message(err, err_cap, "DuckDB table STRUCT argument is too large for R");
        return 0;
    }
    list = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)n));
    names = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)n));
    for (idx_t i = 0; i < n; i++) {
        char *name = duckdb_struct_type_child_name(type, i);
        duckdb_value child = duckdb_get_struct_child(value, i);
        SEXP child_r = R_NilValue;
        SET_STRING_ELT(names, (R_xlen_t)i, Rf_mkChar(name ? name : ""));
        if (name) duckdb_free(name);
        if (!child) {
            UNPROTECT(2);
            rducks_format_error_message(err, err_cap, "failed to read DuckDB table STRUCT argument child");
            return 0;
        }
        if (!rducks_r_table_duckdb_value_to_r(child, &child_r, err, err_cap)) {
            duckdb_destroy_value(&child);
            UNPROTECT(2);
            return 0;
        }
        SET_VECTOR_ELT(list, (R_xlen_t)i, child_r);
        duckdb_destroy_value(&child);
    }
    Rf_setAttrib(list, R_NamesSymbol, names);
    UNPROTECT(2);
    *out = list;
    return 1;
}

static int rducks_r_table_duckdb_value_map_to_r(duckdb_value value, SEXP *out, char *err, size_t err_cap) {
    idx_t n = duckdb_get_map_size(value);
    SEXP keys;
    SEXP values;
    SEXP list;
    SEXP names;
    if (n > (idx_t)R_XLEN_T_MAX) {
        rducks_format_error_message(err, err_cap, "DuckDB table MAP argument is too large for R");
        return 0;
    }
    keys = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)n));
    values = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)n));
    for (idx_t i = 0; i < n; i++) {
        duckdb_value key = duckdb_get_map_key(value, i);
        duckdb_value val = duckdb_get_map_value(value, i);
        SEXP key_r = R_NilValue;
        SEXP val_r = R_NilValue;
        if (!key || !val) {
            if (key) duckdb_destroy_value(&key);
            if (val) duckdb_destroy_value(&val);
            UNPROTECT(2);
            rducks_format_error_message(err, err_cap, "failed to read DuckDB table MAP argument entry");
            return 0;
        }
        if (!rducks_r_table_duckdb_value_to_r(key, &key_r, err, err_cap)) {
            duckdb_destroy_value(&key);
            duckdb_destroy_value(&val);
            UNPROTECT(2);
            return 0;
        }
        SET_VECTOR_ELT(keys, (R_xlen_t)i, key_r);
        if (!rducks_r_table_duckdb_value_to_r(val, &val_r, err, err_cap)) {
            duckdb_destroy_value(&key);
            duckdb_destroy_value(&val);
            UNPROTECT(2);
            return 0;
        }
        SET_VECTOR_ELT(values, (R_xlen_t)i, val_r);
        duckdb_destroy_value(&key);
        duckdb_destroy_value(&val);
    }
    list = PROTECT(Rf_allocVector(VECSXP, 2));
    names = PROTECT(Rf_allocVector(STRSXP, 2));
    SET_VECTOR_ELT(list, 0, keys);
    SET_VECTOR_ELT(list, 1, values);
    SET_STRING_ELT(names, 0, Rf_mkChar("keys"));
    SET_STRING_ELT(names, 1, Rf_mkChar("values"));
    Rf_setAttrib(list, R_NamesSymbol, names);
    UNPROTECT(4);
    *out = list;
    return 1;
}

static int rducks_r_table_duckdb_value_to_r(duckdb_value value, SEXP *out, char *err, size_t err_cap) {
    duckdb_logical_type type;
    duckdb_type type_id;
    int ok = 1;
    if (!value || !out) {
        rducks_format_error_message(err, err_cap, "invalid DuckDB table argument value");
        return 0;
    }
    if (duckdb_is_null_value(value)) {
        *out = R_NilValue;
        return 1;
    }
    type = duckdb_get_value_type(value);
    if (!type) {
        rducks_format_error_message(err, err_cap, "failed to inspect DuckDB table argument type");
        return 0;
    }
    type_id = duckdb_get_type_id(type);
    switch (type_id) {
    case DUCKDB_TYPE_BOOLEAN:
        *out = Rf_ScalarLogical(duckdb_get_bool(value) ? TRUE : FALSE);
        break;
    case DUCKDB_TYPE_TINYINT:
        *out = Rf_ScalarInteger((int)duckdb_get_int8(value));
        break;
    case DUCKDB_TYPE_SMALLINT:
        *out = Rf_ScalarInteger((int)duckdb_get_int16(value));
        break;
    case DUCKDB_TYPE_INTEGER:
        *out = Rf_ScalarInteger((int)duckdb_get_int32(value));
        break;
    case DUCKDB_TYPE_INTEGER_LITERAL: {
        int64_t v = duckdb_get_int64(value);
        *out = (v >= (int64_t)INT32_MIN && v <= (int64_t)INT32_MAX) ?
            Rf_ScalarInteger((int)v) : rducks_r_table_bigint_scalar(v);
        break;
    }
    case DUCKDB_TYPE_UTINYINT:
        *out = Rf_ScalarInteger((int)duckdb_get_uint8(value));
        break;
    case DUCKDB_TYPE_USMALLINT:
        *out = Rf_ScalarInteger((int)duckdb_get_uint16(value));
        break;
    case DUCKDB_TYPE_UINTEGER:
        *out = rducks_r_table_uint64_scalar((uint64_t)duckdb_get_uint32(value));
        break;
    case DUCKDB_TYPE_BIGINT:
        *out = rducks_r_table_bigint_scalar(duckdb_get_int64(value));
        break;
    case DUCKDB_TYPE_UBIGINT:
        *out = rducks_r_table_ubigint_scalar(duckdb_get_uint64(value));
        break;
    case DUCKDB_TYPE_FLOAT:
        *out = Rf_ScalarReal((double)duckdb_get_float(value));
        break;
    case DUCKDB_TYPE_DOUBLE:
        *out = Rf_ScalarReal(duckdb_get_double(value));
        break;
    case DUCKDB_TYPE_DATE: {
        duckdb_date date = duckdb_get_date(value);
        *out = rducks_r_table_date((double)date.days);
        break;
    }
    case DUCKDB_TYPE_TIME: {
        duckdb_time time = duckdb_get_time(value);
        *out = Rf_ScalarReal((double)time.micros / 1000000.0);
        break;
    }
    case DUCKDB_TYPE_TIME_NS: {
        duckdb_time_ns time = duckdb_get_time_ns(value);
        *out = Rf_ScalarReal((double)time.nanos / 1000000000.0);
        break;
    }
    case DUCKDB_TYPE_TIMESTAMP: {
        duckdb_timestamp ts = duckdb_get_timestamp(value);
        *out = rducks_r_table_posixct((double)ts.micros / 1000000.0);
        break;
    }
    case DUCKDB_TYPE_TIMESTAMP_TZ: {
        duckdb_timestamp ts = duckdb_get_timestamp_tz(value);
        *out = rducks_r_table_posixct((double)ts.micros / 1000000.0);
        break;
    }
    case DUCKDB_TYPE_TIMESTAMP_S: {
        duckdb_timestamp_s ts = duckdb_get_timestamp_s(value);
        *out = rducks_r_table_posixct((double)ts.seconds);
        break;
    }
    case DUCKDB_TYPE_TIMESTAMP_MS: {
        duckdb_timestamp_ms ts = duckdb_get_timestamp_ms(value);
        *out = rducks_r_table_posixct((double)ts.millis / 1000.0);
        break;
    }
    case DUCKDB_TYPE_TIMESTAMP_NS: {
        duckdb_timestamp_ns ts = duckdb_get_timestamp_ns(value);
        *out = rducks_r_table_posixct((double)ts.nanos / 1000000000.0);
        break;
    }
    case DUCKDB_TYPE_VARCHAR:
    case DUCKDB_TYPE_STRING_LITERAL:
    case DUCKDB_TYPE_ENUM:
    case DUCKDB_TYPE_UUID:
    case DUCKDB_TYPE_BIT:
    case DUCKDB_TYPE_DECIMAL:
    case DUCKDB_TYPE_HUGEINT:
    case DUCKDB_TYPE_UHUGEINT:
    case DUCKDB_TYPE_BIGNUM:
        ok = rducks_r_table_duckdb_value_string_to_r(value, out, err, err_cap);
        break;
    case DUCKDB_TYPE_BLOB:
    case DUCKDB_TYPE_GEOMETRY:
        ok = rducks_r_table_duckdb_value_blob_to_r(value, out, err, err_cap);
        break;
    case DUCKDB_TYPE_LIST:
    case DUCKDB_TYPE_ARRAY:
        ok = rducks_r_table_duckdb_value_list_to_r(value, out, err, err_cap);
        break;
    case DUCKDB_TYPE_STRUCT:
        ok = rducks_r_table_duckdb_value_struct_to_r(value, type, out, err, err_cap);
        break;
    case DUCKDB_TYPE_MAP:
        ok = rducks_r_table_duckdb_value_map_to_r(value, out, err, err_cap);
        break;
    case DUCKDB_TYPE_INTERVAL: {
        duckdb_interval interval = duckdb_get_interval(value);
        SEXP list = PROTECT(Rf_allocVector(VECSXP, 3));
        SEXP names = PROTECT(Rf_allocVector(STRSXP, 3));
        SET_VECTOR_ELT(list, 0, Rf_ScalarInteger(interval.months));
        SET_VECTOR_ELT(list, 1, Rf_ScalarInteger(interval.days));
        SET_VECTOR_ELT(list, 2, rducks_r_table_bigint_scalar(interval.micros));
        SET_STRING_ELT(names, 0, Rf_mkChar("months"));
        SET_STRING_ELT(names, 1, Rf_mkChar("days"));
        SET_STRING_ELT(names, 2, Rf_mkChar("micros"));
        Rf_setAttrib(list, R_NamesSymbol, names);
        UNPROTECT(2);
        *out = list;
        break;
    }
    case DUCKDB_TYPE_SQLNULL:
    case DUCKDB_TYPE_ANY:
        *out = R_NilValue;
        break;
    default: {
        char *text = duckdb_value_to_string(value);
        if (text) {
            *out = Rf_mkString(text);
            duckdb_free(text);
        } else {
            rducks_format_error_message(err, err_cap, "unsupported DuckDB table argument type id %d", (int)type_id);
            ok = 0;
        }
        break;
    }
    }
    return ok;
}

static rducks_type_desc_t *rducks_r_table_scalar_desc(rducks_type_id_t scalar) {
    rducks_type_desc_t *desc = rducks_type_desc_new(RDUCKS_KIND_SCALAR);
    if (desc) desc->scalar = scalar;
    return desc;
}

static int rducks_r_table_name_seen(char **names, size_t count, const char *name) {
    for (size_t i = 0; i < count; i++) {
        if (names[i] && name && strcmp(names[i], name) == 0) return 1;
    }
    return 0;
}

static int rducks_r_table_is_blob_list(SEXP column) {
    R_xlen_t n = XLENGTH(column);
    if (TYPEOF(column) != VECSXP) return 0;
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP item = VECTOR_ELT(column, i);
        if (item != R_NilValue && TYPEOF(item) != RAWSXP) return 0;
    }
    return 1;
}

static rducks_type_desc_t *rducks_r_table_enum_desc(SEXP column, const char *name, char *err, size_t err_cap) {
    SEXP levels = Rf_getAttrib(column, R_LevelsSymbol);
    R_xlen_t nlevels;
    rducks_type_desc_t *desc;
    if (TYPEOF(levels) != STRSXP || XLENGTH(levels) <= 0) {
        rducks_format_error_message(err, err_cap, "Rducks table factor column %s must have non-empty character levels", name);
        return NULL;
    }
    nlevels = XLENGTH(levels);
    if ((uint64_t)nlevels > (uint64_t)SIZE_MAX) {
        rducks_format_error_message(err, err_cap, "Rducks table factor column %s has too many levels", name);
        return NULL;
    }
    desc = rducks_type_desc_new(RDUCKS_KIND_ENUM);
    if (!desc) {
        rducks_format_error_message(err, err_cap, "out of memory inferring Rducks table factor column");
        return NULL;
    }
    desc->field_names = (char **)rducks_calloc_array((size_t)nlevels, sizeof(*desc->field_names));
    if (!desc->field_names) {
        rducks_format_error_message(err, err_cap, "out of memory inferring Rducks table factor column");
        rducks_type_desc_destroy(desc);
        return NULL;
    }
    for (R_xlen_t i = 0; i < nlevels; i++) {
        SEXP level = STRING_ELT(levels, i);
        const char *text;
        if (level == NA_STRING) {
            rducks_format_error_message(err, err_cap, "Rducks table factor column %s has an NA level", name);
            rducks_type_desc_destroy(desc);
            return NULL;
        }
        text = CHAR(level);
        if (!text[0]) {
            rducks_format_error_message(err, err_cap, "Rducks table factor column %s has an empty level", name);
            rducks_type_desc_destroy(desc);
            return NULL;
        }
        desc->field_names[(size_t)i] = rducks_strdup(text);
        if (!desc->field_names[(size_t)i]) {
            rducks_format_error_message(err, err_cap, "out of memory inferring Rducks table factor column");
            rducks_type_desc_destroy(desc);
            return NULL;
        }
        desc->field_count = (size_t)i + 1U;
    }
    if (!rducks_type_desc_build_field_hash(desc)) {
        rducks_format_error_message(err, err_cap, "out of memory indexing Rducks table factor column levels");
        rducks_type_desc_destroy(desc);
        return NULL;
    }
    return desc;
}

static rducks_type_desc_t *rducks_r_table_infer_column_desc(SEXP column, const char *name,
                                                            char *err, size_t err_cap) {
    if (Rf_inherits(column, "POSIXct")) return rducks_r_table_scalar_desc(RDUCKS_TYPE_TIMESTAMP);
    if (Rf_inherits(column, "Date")) return rducks_r_table_scalar_desc(RDUCKS_TYPE_DATE);
    if (Rf_inherits(column, "factor")) return rducks_r_table_enum_desc(column, name, err, err_cap);
    switch (TYPEOF(column)) {
    case LGLSXP:
        return rducks_r_table_scalar_desc(RDUCKS_TYPE_BOOL);
    case INTSXP:
        return rducks_r_table_scalar_desc(RDUCKS_TYPE_I32);
    case REALSXP:
        return rducks_r_table_scalar_desc(RDUCKS_TYPE_F64);
    case STRSXP:
        return rducks_r_table_scalar_desc(RDUCKS_TYPE_VARCHAR);
    case VECSXP:
        if (rducks_r_table_is_blob_list(column)) return rducks_r_table_scalar_desc(RDUCKS_TYPE_BLOB);
        break;
    default:
        break;
    }
    rducks_format_error_message(err, err_cap,
             "unsupported Rducks table column type for %s; supported inferred columns are logical, integer, numeric, character, factor, Date, POSIXct, and list-of-raw BLOB",
             name ? name : "<unnamed>");
    return NULL;
}

/* Direct: build an owned DuckDB data chunk from an R data frame (a VECSXP of
 * equal-length columns) using the already-inferred column descriptors. Reuses
 * the same direct DuckDB-vector writers used by scalar-UDF result writeback, so
 * there is no wire serialization for the in-process scan. */
static int rducks_r_table_chunk_from_df(rducks_r_table_bind_t *bind, SEXP df, idx_t rows,
                                        duckdb_data_chunk *chunk_out, char *err, size_t err_cap) {
    duckdb_logical_type *types = NULL;
    duckdb_data_chunk chunk = NULL;
    size_t ncol;
    int ok = 0;
    if (chunk_out) *chunk_out = NULL;
    if (!bind || !bind->column_descs) {
        rducks_format_error_message(err, err_cap, "Rducks table bind metadata is missing");
        return 0;
    }
    ncol = bind->column_count;
    if (TYPEOF(df) != VECSXP || (size_t)XLENGTH(df) != ncol) {
        rducks_format_error_message(err, err_cap, "Rducks table batch shape does not match the bound columns");
        return 0;
    }
    types = (duckdb_logical_type *)rducks_calloc_array(ncol, sizeof(*types));
    if (!types) {
        rducks_format_error_message(err, err_cap, "out of memory allocating Rducks table chunk types");
        return 0;
    }
    for (size_t c = 0; c < ncol; c++) {
        types[c] = rducks_create_logical_type_for_desc(bind->column_descs[c]);
        if (!types[c]) {
            rducks_format_error_message(err, err_cap, "failed to build Rducks table column logical type");
            goto cleanup;
        }
    }
    chunk = duckdb_create_data_chunk(types, (idx_t)ncol);
    if (!chunk) {
        rducks_format_error_message(err, err_cap, "failed to allocate Rducks table data chunk");
        goto cleanup;
    }
    duckdb_data_chunk_set_size(chunk, rows);
    for (size_t c = 0; c < ncol; c++) {
        duckdb_vector vec = duckdb_data_chunk_get_vector(chunk, (idx_t)c);
        rducks_rc_direct_vector_view_t view;
        SEXP col = VECTOR_ELT(df, (R_xlen_t)c);
        if (!vec) {
            rducks_format_error_message(err, err_cap, "Rducks table chunk vector is missing");
            goto cleanup;
        }
        if ((idx_t)XLENGTH(col) != rows) {
            rducks_format_error_message(err, err_cap, "Rducks table column length does not match the row count");
            goto cleanup;
        }
        rducks_rc_direct_view_init(&view, vec);
        for (idx_t r = 0; r < rows; r++) {
            int vok = 1;
            SEXP value = PROTECT(rducks_rc_vector_value_at(col, r, &vok));
            int wrote = vok && rducks_rc_write_direct_output(bind->column_descs[c], &view, r, value, err, err_cap);
            UNPROTECT(1);
            if (!wrote) {
                if (!err[0]) rducks_format_error_message(err, err_cap, "failed to write Rducks table cell value");
                goto cleanup;
            }
        }
    }
    *chunk_out = chunk;
    chunk = NULL;
    ok = 1;
cleanup:
    if (chunk) duckdb_destroy_data_chunk(&chunk);
    if (types) {
        for (size_t c = 0; c < ncol; c++) {
            if (types[c]) duckdb_destroy_logical_type(&types[c]);
        }
        free(types);
    }
    return ok;
}

static int rducks_r_table_call_namespace_fun1(const char *fun_name, SEXP arg, SEXP *out,
                                             const char *fallback, char *err, size_t err_cap) {
    int r_err = 0;
    int protect_count = 0;
    SEXP pkg = PROTECT(Rf_mkString("Rducks"));
    protect_count++;
    SEXP ns = PROTECT(R_FindNamespace(pkg));
    protect_count++;
    SEXP fun = PROTECT(Rf_findFun(Rf_install(fun_name), ns));
    protect_count++;
    SEXP call = PROTECT(Rf_lang2(fun, arg));
    protect_count++;
    SEXP result = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, &r_err));
    protect_count++;
    if (r_err) {
        rducks_r_table_set_r_error(result, fallback, err, err_cap);
        UNPROTECT(protect_count);
        return 0;
    }
    R_PreserveObject(result);
    *out = result;
    UNPROTECT(protect_count);
    return 1;
}

static int rducks_r_table_stream_prototype(SEXP stream, SEXP *prototype_out, char *err, size_t err_cap) {
    return rducks_r_table_call_namespace_fun1("rducks_table_stream_prototype", stream, prototype_out,
                                              "Rducks table stream prototype error", err, err_cap);
}

static int rducks_r_table_stream_cardinality(SEXP stream, int *known_out, idx_t *rows_out, int *exact_out,
                                             char *err, size_t err_cap) {
    SEXP info = R_NilValue;
    SEXP known;
    SEXP rows;
    SEXP exact;
    double rows_d;
    if (known_out) *known_out = 0;
    if (rows_out) *rows_out = 0;
    if (exact_out) *exact_out = 0;
    if (!rducks_r_table_call_namespace_fun1("rducks_table_stream_cardinality", stream, &info,
                                            "Rducks table stream cardinality error", err, err_cap)) {
        return 0;
    }
    if (TYPEOF(info) != VECSXP) {
        rducks_format_error_message(err, err_cap, "Rducks table stream cardinality helper returned invalid metadata");
        R_ReleaseObject(info);
        return 0;
    }
    known = rducks_named_list_get(info, "known");
    rows = rducks_named_list_get(info, "rows");
    exact = rducks_named_list_get(info, "exact");
    if (!Rf_isLogical(known) || XLENGTH(known) != 1 || LOGICAL(known)[0] != TRUE) {
        R_ReleaseObject(info);
        return 1;
    }
    rows_d = Rf_asReal(rows);
    if (!isfinite(rows_d) || rows_d < 0 || rows_d != floor(rows_d) || rows_d > (double)((idx_t)-1)) {
        rducks_format_error_message(err, err_cap, "Rducks table stream cardinality is invalid or too large");
        R_ReleaseObject(info);
        return 0;
    }
    if (known_out) *known_out = 1;
    if (rows_out) *rows_out = (idx_t)rows_d;
    if (exact_out) *exact_out = (Rf_isLogical(exact) && XLENGTH(exact) == 1 && LOGICAL(exact)[0] == TRUE) ? 1 : 0;
    R_ReleaseObject(info);
    return 1;
}

static int rducks_r_table_import_result(rducks_r_table_bind_t *bind, SEXP result,
                                        char *err, size_t err_cap) {
    if (!bind || !bind->meta || !bind->meta->runtime) {
        rducks_format_error_message(err, err_cap, "Rducks table runtime is unavailable for result import");
        return 0;
    }
    return rducks_r_table_chunk_from_df(bind, result, bind->rows, &bind->imported_chunk, err, err_cap);
}

static int rducks_r_table_bind_result(rducks_r_table_meta_t *meta, SEXP result,
                                      duckdb_bind_info info, char *err, size_t err_cap) {
    SEXP schema_result = result;
    SEXP names;
    R_xlen_t ncols_x;
    idx_t rows = 0;
    int have_rows = 0;
    int is_streaming = Rf_inherits(result, "rducks_table_stream") ? 1 : 0;
    int release_schema_result = 0;
    int cardinality_known = 0;
    int cardinality_exact = 0;
    idx_t cardinality = 0;
    rducks_r_table_bind_t *bind = NULL;

    if (is_streaming) {
        if (!rducks_r_table_stream_prototype(result, &schema_result, err, err_cap)) return 0;
        release_schema_result = 1;
        if (!rducks_r_table_stream_cardinality(result, &cardinality_known, &cardinality,
                                               &cardinality_exact, err, err_cap)) {
            R_ReleaseObject(schema_result);
            return 0;
        }
    }

    if (TYPEOF(schema_result) != VECSXP) {
        rducks_format_error_message(err, err_cap, is_streaming ?
                 "Rducks table stream prototype must be a data frame or named list of columns" :
                 "Rducks table function must return a data frame or named list of columns");
        if (release_schema_result) R_ReleaseObject(schema_result);
        return 0;
    }
    names = Rf_getAttrib(schema_result, R_NamesSymbol);
    ncols_x = XLENGTH(schema_result);
    if (ncols_x <= 0) {
        rducks_format_error_message(err, err_cap, "Rducks table function must return at least one column");
        if (release_schema_result) R_ReleaseObject(schema_result);
        return 0;
    }
    if (TYPEOF(names) != STRSXP || XLENGTH(names) != ncols_x) {
        rducks_format_error_message(err, err_cap, "Rducks table function result columns must be named");
        if (release_schema_result) R_ReleaseObject(schema_result);
        return 0;
    }
    if ((uint64_t)ncols_x > (uint64_t)SIZE_MAX) {
        rducks_format_error_message(err, err_cap, "Rducks table function returned too many columns");
        if (release_schema_result) R_ReleaseObject(schema_result);
        return 0;
    }

    bind = (rducks_r_table_bind_t *)rducks_calloc_array(1, sizeof(*bind));
    if (!bind) {
        rducks_format_error_message(err, err_cap, "out of memory allocating Rducks table bind data");
        if (release_schema_result) R_ReleaseObject(schema_result);
        return 0;
    }
    atomic_init(&bind->refcount, 1U);
    bind->meta = meta;
    bind->result = R_NilValue;
    bind->column_count = (size_t)ncols_x;
    bind->imported_chunk = NULL;
    bind->streaming = is_streaming;
    bind->cardinality_known = cardinality_known;
    bind->cardinality_exact = cardinality_exact;
    bind->cardinality = cardinality;
    bind->column_names = (char **)rducks_calloc_array(bind->column_count, sizeof(*bind->column_names));
    bind->column_descs = (rducks_type_desc_t **)rducks_calloc_array(bind->column_count, sizeof(*bind->column_descs));
    if (!bind->column_names || !bind->column_descs) {
        rducks_format_error_message(err, err_cap, "out of memory allocating Rducks table column metadata");
        rducks_r_table_bind_destroy(bind);
        if (release_schema_result) R_ReleaseObject(schema_result);
        return 0;
    }

    for (size_t col = 0; col < bind->column_count; col++) {
        SEXP name_sexp = STRING_ELT(names, (R_xlen_t)col);
        SEXP column;
        R_xlen_t len;
        duckdb_logical_type type;
        const char *name_text;
        if (name_sexp == NA_STRING || !CHAR(name_sexp)[0]) {
            rducks_format_error_message(err, err_cap, "Rducks table function result columns must have non-empty names");
            rducks_r_table_bind_destroy(bind);
            if (release_schema_result) R_ReleaseObject(schema_result);
            return 0;
        }
        name_text = CHAR(name_sexp);
        if (rducks_r_table_name_seen(bind->column_names, col, name_text)) {
            rducks_format_error_message(err, err_cap, "Rducks table function result column names must be unique");
            rducks_r_table_bind_destroy(bind);
            if (release_schema_result) R_ReleaseObject(schema_result);
            return 0;
        }
        bind->column_names[col] = rducks_strdup(name_text);
        if (!bind->column_names[col]) {
            rducks_format_error_message(err, err_cap, "out of memory copying Rducks table column name");
            rducks_r_table_bind_destroy(bind);
            if (release_schema_result) R_ReleaseObject(schema_result);
            return 0;
        }
        column = VECTOR_ELT(schema_result, (R_xlen_t)col);
        len = XLENGTH(column);
        if (len < 0 || (uint64_t)len > (uint64_t)((idx_t)-1)) {
            rducks_format_error_message(err, err_cap, "Rducks table column %s has invalid length", bind->column_names[col]);
            rducks_r_table_bind_destroy(bind);
            if (release_schema_result) R_ReleaseObject(schema_result);
            return 0;
        }
        if (!have_rows) {
            rows = (idx_t)len;
            have_rows = 1;
        } else if (rows != (idx_t)len) {
            rducks_format_error_message(err, err_cap, "Rducks table result columns must have equal lengths");
            rducks_r_table_bind_destroy(bind);
            if (release_schema_result) R_ReleaseObject(schema_result);
            return 0;
        }
        bind->column_descs[col] = rducks_r_table_infer_column_desc(column, bind->column_names[col], err, err_cap);
        if (!bind->column_descs[col]) {
            if (!err[0]) rducks_format_error_message(err, err_cap, "failed to infer Rducks table column type");
            rducks_r_table_bind_destroy(bind);
            if (release_schema_result) R_ReleaseObject(schema_result);
            return 0;
        }
        type = rducks_create_logical_type_for_desc(bind->column_descs[col]);
        if (!type) {
            rducks_format_error_message(err, err_cap, "failed to allocate DuckDB logical type for Rducks table column %s", bind->column_names[col]);
            rducks_r_table_bind_destroy(bind);
            if (release_schema_result) R_ReleaseObject(schema_result);
            return 0;
        }
        duckdb_bind_add_result_column(info, bind->column_names[col], type);
        duckdb_destroy_logical_type(&type);
    }

    R_PreserveObject(result);
    bind->result = result;
    bind->rows = rows;
    if (is_streaming) {
        if (cardinality_known) duckdb_bind_set_cardinality(info, cardinality, cardinality_exact ? true : false);
    } else {
        if (!rducks_r_table_import_result(bind, result, err, err_cap)) {
            rducks_r_table_bind_destroy(bind);
            if (release_schema_result) R_ReleaseObject(schema_result);
            return 0;
        }
        duckdb_bind_set_cardinality(info, rows, true);
    }
    duckdb_bind_set_bind_data(info, bind, rducks_r_table_bind_destroy);
    if (release_schema_result) R_ReleaseObject(schema_result);
    return 1;
}

static void rducks_r_table_bind(duckdb_bind_info info) {
    rducks_r_table_meta_t *meta;
    int r_err = 0;
    char err[RDUCKS_ERROR_BUFFER_SIZE];
    SEXP args;
    SEXP result;
    if (!info) return;
    err[0] = '\0';
    meta = (rducks_r_table_meta_t *)duckdb_bind_get_extra_info(info);
    if (!meta) {
        duckdb_bind_set_error(info, "Rducks table metadata is missing");
        return;
    }
    if (duckdb_bind_get_parameter_count(info) != meta->parameter_count) {
        duckdb_bind_set_error(info, "Rducks R table function SQL argument count does not match the registered R function formals");
        return;
    }
    if (!meta->runtime || !Rf_isFunction(meta->fun)) {
        duckdb_bind_set_error(info, "Rducks table state is invalid");
        return;
    }
    if (!rducks_allow_calling_thread_r_execution(meta->runtime, err, sizeof(err))) {
        duckdb_bind_set_error(info, err[0] ? err : "Rducks table bind must run on the recorded R thread");
        return;
    }
    rducks_preserved_release_drain_on_main(meta->runtime);

    args = PROTECT(Rf_allocList((int)meta->parameter_count));
    SEXP node = args;
    for (idx_t i = 0; i < meta->parameter_count; i++) {
        duckdb_value value = duckdb_bind_get_parameter(info, i);
        SEXP arg = R_NilValue;
        if (!value) {
            duckdb_bind_set_error(info, "failed to read Rducks table SQL argument");
            UNPROTECT(1);
            return;
        }
        if (!rducks_r_table_duckdb_value_to_r(value, &arg, err, sizeof(err))) {
            duckdb_destroy_value(&value);
            duckdb_bind_set_error(info, err[0] ? err : "failed to convert Rducks table SQL argument to R");
            UNPROTECT(1);
            return;
        }
        SETCAR(node, arg);
        node = CDR(node);
        duckdb_destroy_value(&value);
    }

    result = PROTECT(rducks_rc_call_user(meta->fun, args, &r_err));
    if (r_err) {
        rducks_r_table_set_r_error(result, "Rducks table R function or marshal error", err, sizeof(err));
        duckdb_bind_set_error(info, err[0] ? err : "Rducks table R function failed");
        UNPROTECT(2);
        return;
    }
    if (!rducks_r_table_bind_result(meta, result, info, err, sizeof(err))) {
        duckdb_bind_set_error(info, err[0] ? err : "Rducks table bind failed");
        UNPROTECT(2);
        return;
    }
    UNPROTECT(2);
}

static int rducks_r_table_state_init_projection(rducks_r_table_state_t *state,
                                                 duckdb_init_info info,
                                                 char *err, size_t err_cap) {
    idx_t projected_count;
    idx_t sel_capacity;

    if (!state || !state->bind || !info) {
        rducks_format_error_message(err, err_cap, "invalid Rducks table projection state");
        return 0;
    }

    projected_count = duckdb_init_get_column_count(info);
    state->projected_count = projected_count;
    if (projected_count > 0) {
        if ((uint64_t)projected_count > (uint64_t)(SIZE_MAX / sizeof(*state->projected_columns))) {
            rducks_format_error_message(err, err_cap, "Rducks table projection is too large");
            return 0;
        }
        state->projected_columns = (idx_t *)rducks_calloc_array((size_t)projected_count, sizeof(*state->projected_columns));
        if (!state->projected_columns) {
            rducks_format_error_message(err, err_cap, "out of memory allocating Rducks table projection state");
            return 0;
        }
        for (idx_t i = 0; i < projected_count; i++) {
            idx_t col = duckdb_init_get_column_index(info, i);
            if (col >= (idx_t)state->bind->column_count) {
                rducks_format_error_message(err, err_cap, "Rducks table projection column is outside the table schema");
                return 0;
            }
            state->projected_columns[i] = col;
        }
    }

    if (projected_count > 0) {
        sel_capacity = state->bind->meta ? state->bind->meta->chunk_size : 0;
        if (sel_capacity < 1) sel_capacity = 1;
        state->sel = duckdb_create_selection_vector(sel_capacity);
        if (!state->sel) {
            rducks_format_error_message(err, err_cap, "failed to allocate DuckDB selection vector for Rducks table scan");
            return 0;
        }
        state->sel_capacity = sel_capacity;
    }
    return 1;
}

static int rducks_r_table_stream_next_array_xptr(rducks_r_table_state_t *state,
                                                   SEXP *array_xptr_out,
                                                   char *err, size_t err_cap) {
    int r_err = 0;
    int protect_count = 0;
    rducks_r_table_bind_t *bind = state ? state->bind : NULL;
    rducks_r_table_meta_t *meta = bind ? bind->meta : NULL;
    SEXP pkg;
    SEXP ns;
    SEXP fun;
    SEXP n_arg;
    SEXP call;
    SEXP result;
    if (array_xptr_out) *array_xptr_out = R_NilValue;
    if (!state || !bind || !meta || bind->result == R_NilValue) {
        rducks_format_error_message(err, err_cap, "Rducks table stream state is missing");
        return 0;
    }
    pkg = PROTECT(Rf_mkString("Rducks"));
    protect_count++;
    ns = PROTECT(R_FindNamespace(pkg));
    protect_count++;
    fun = PROTECT(Rf_findFun(Rf_install("rducks_table_stream_next_array"), ns));
    protect_count++;
    n_arg = PROTECT(Rf_ScalarReal((double)meta->chunk_size));
    protect_count++;
    call = PROTECT(Rf_lang3(fun, bind->result, n_arg));
    protect_count++;
    result = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, &r_err));
    protect_count++;
    if (r_err) {
        rducks_r_table_set_r_error(result, "Rducks table stream next_batch error", err, err_cap);
        UNPROTECT(protect_count);
        return 0;
    }
    if (result == R_NilValue) {
        if (array_xptr_out) *array_xptr_out = R_NilValue;
        UNPROTECT(protect_count);
        return 1;
    }
    if (TYPEOF(result) != VECSXP) {
        rducks_format_error_message(err, err_cap, "Rducks table stream next_batch must return a data frame batch or NULL");
        UNPROTECT(protect_count);
        return 0;
    }
    R_PreserveObject(result);
    if (array_xptr_out) *array_xptr_out = result;
    UNPROTECT(protect_count);
    return 1;
}

static int rducks_r_table_stream_load_next_chunk(rducks_r_table_state_t *state,
                                                 char *err, size_t err_cap) {
    SEXP df = R_NilValue;
    rducks_r_table_bind_t *bind = state ? state->bind : NULL;
    idx_t rows;
    duckdb_data_chunk chunk = NULL;
    if (!state || !bind || !bind->meta) {
        rducks_format_error_message(err, err_cap, "Rducks table stream state is missing");
        return 0;
    }
    if (state->current_chunk) {
        duckdb_destroy_data_chunk(&state->current_chunk);
        state->current_rows = 0;
        state->current_pos = 0;
    }
    if (!rducks_r_table_stream_next_array_xptr(state, &df, err, err_cap)) return 0;
    if (df == R_NilValue) {
        state->stream_done = 1;
        return 1;
    }
    if (TYPEOF(df) != VECSXP || (size_t)XLENGTH(df) != bind->column_count || XLENGTH(df) == 0) {
        R_ReleaseObject(df);
        rducks_format_error_message(err, err_cap, "Rducks table stream batch shape does not match the bound columns");
        return 0;
    }
    rows = (idx_t)XLENGTH(VECTOR_ELT(df, 0));
    if (rows == 0) {
        R_ReleaseObject(df);
        rducks_format_error_message(err, err_cap, "Rducks table stream next_batch returned an empty batch; return NULL to signal end-of-stream");
        return 0;
    }
    if (!rducks_r_table_chunk_from_df(bind, df, rows, &chunk, err, err_cap)) {
        R_ReleaseObject(df);
        return 0;
    }
    R_ReleaseObject(df);
    state->current_chunk = chunk;
    state->current_rows = rows;
    state->current_pos = 0;
    return 1;
}

static int rducks_r_table_copy_projected_rows(duckdb_function_info info,
                                              rducks_r_table_state_t *state,
                                              duckdb_data_chunk source,
                                              idx_t source_pos,
                                              idx_t count,
                                              duckdb_data_chunk output) {
    idx_t output_columns = duckdb_data_chunk_get_column_count(output);
    if (output_columns != state->projected_count) {
        duckdb_function_set_error(info, "Rducks table output projection does not match DuckDB scan state");
        return 0;
    }
    if (state->projected_count == 0) return 1;
    if (!source) {
        duckdb_function_set_error(info, "Rducks table imported source chunk is missing");
        return 0;
    }
    if (count > (idx_t)UINT32_MAX || source_pos > (idx_t)UINT32_MAX || source_pos + count > (idx_t)UINT32_MAX) {
        duckdb_function_set_error(info, "Rducks table chunk offset is too large for DuckDB selection vector copy");
        return 0;
    }
    if (!state->sel || state->sel_capacity < count) {
        if (state->sel) duckdb_destroy_selection_vector(state->sel);
        state->sel = duckdb_create_selection_vector(count);
        if (!state->sel) {
            duckdb_function_set_error(info, "failed to allocate DuckDB selection vector for Rducks table scan");
            state->sel_capacity = 0;
            return 0;
        }
        state->sel_capacity = count;
    }
    sel_t *sel_data = duckdb_selection_vector_get_data_ptr(state->sel);
    for (idx_t row = 0; row < count; row++) sel_data[row] = (sel_t)(source_pos + row);
    for (idx_t out_col = 0; out_col < state->projected_count; out_col++) {
        idx_t src_col = state->projected_columns ? state->projected_columns[out_col] : out_col;
        duckdb_vector imported = duckdb_data_chunk_get_vector(source, src_col);
        duckdb_vector vector = duckdb_data_chunk_get_vector(output, out_col);
        duckdb_vector_copy_sel(imported, vector, state->sel, count, 0, 0);
    }
    return 1;
}

static void rducks_r_table_init(duckdb_init_info info) {
    rducks_r_table_state_t *state;
    char err[RDUCKS_ERROR_BUFFER_SIZE];
    if (!info) return;
    err[0] = '\0';
    state = (rducks_r_table_state_t *)rducks_calloc_array(1, sizeof(*state));
    if (!state) {
        duckdb_init_set_error(info, "out of memory allocating Rducks table state");
        return;
    }
    state->bind = (rducks_r_table_bind_t *)duckdb_init_get_bind_data(info);
    state->pos = 0;
    if (!state->bind) {
        rducks_r_table_state_destroy(state);
        duckdb_init_set_error(info, "Rducks table bind data is missing");
        return;
    }
    rducks_r_table_bind_retain(state->bind);
    if (!rducks_r_table_state_init_projection(state, info, err, sizeof(err))) {
        rducks_r_table_state_destroy(state);
        duckdb_init_set_error(info, err[0] ? err : "failed to initialize Rducks table projection state");
        return;
    }
    duckdb_init_set_max_threads(info, 1);
    duckdb_init_set_init_data(info, state, rducks_r_table_state_destroy);
}

static void rducks_r_table_function(duckdb_function_info info, duckdb_data_chunk output) {
    rducks_r_table_state_t *state;
    rducks_r_table_bind_t *bind;
    rducks_r_table_meta_t *meta;
    idx_t remaining;
    idx_t count;
    char err[RDUCKS_ERROR_BUFFER_SIZE];
    if (!info || !output) return;
    err[0] = '\0';
    state = (rducks_r_table_state_t *)duckdb_function_get_init_data(info);
    bind = state ? state->bind : NULL;
    meta = bind ? bind->meta : NULL;
    if (!state || !bind || !meta) {
        duckdb_function_set_error(info, "Rducks table state is missing");
        duckdb_data_chunk_set_size(output, 0);
        return;
    }
    if (!rducks_allow_calling_thread_r_execution(meta->runtime, err, sizeof(err))) {
        duckdb_function_set_error(info, err[0] ? err : "Rducks table scan must run on the recorded R thread");
        duckdb_data_chunk_set_size(output, 0);
        return;
    }
    rducks_preserved_release_drain_on_main(meta->runtime);

    if (bind->streaming) {
        while ((!state->current_chunk || state->current_pos >= state->current_rows) && !state->stream_done) {
            if (!rducks_r_table_stream_load_next_chunk(state, err, sizeof(err))) {
                duckdb_function_set_error(info, err[0] ? err : "Rducks table stream failed to produce a batch");
                duckdb_data_chunk_set_size(output, 0);
                return;
            }
        }
        if (!state->current_chunk || state->current_pos >= state->current_rows) {
            if (bind->cardinality_known && bind->cardinality_exact && state->pos != bind->cardinality) {
                duckdb_function_set_error(info, "Rducks table stream emitted a different row count than its exact cardinality");
            }
            duckdb_data_chunk_set_size(output, 0);
            return;
        }
        remaining = state->current_rows - state->current_pos;
        count = remaining < meta->chunk_size ? remaining : meta->chunk_size;
        if (bind->cardinality_known && bind->cardinality_exact &&
            (state->pos > bind->cardinality || count > bind->cardinality - state->pos)) {
            duckdb_function_set_error(info, "Rducks table stream emitted more rows than its exact cardinality");
            duckdb_data_chunk_set_size(output, 0);
            return;
        }
        if (!rducks_r_table_copy_projected_rows(info, state, state->current_chunk,
                                                state->current_pos, count, output)) {
            duckdb_data_chunk_set_size(output, 0);
            return;
        }
        state->current_pos += count;
        state->pos += count;
        if (state->current_pos >= state->current_rows) {
            duckdb_destroy_data_chunk(&state->current_chunk);
            state->current_rows = 0;
            state->current_pos = 0;
        }
        duckdb_data_chunk_set_size(output, count);
        return;
    }

    if (state->pos >= bind->rows) {
        duckdb_data_chunk_set_size(output, 0);
        return;
    }

    remaining = bind->rows - state->pos;
    count = remaining < meta->chunk_size ? remaining : meta->chunk_size;
    if (!rducks_r_table_copy_projected_rows(info, state, bind->imported_chunk, state->pos, count, output)) {
        duckdb_data_chunk_set_size(output, 0);
        return;
    }

    state->pos += count;
    duckdb_data_chunk_set_size(output, count);
}

static bool rducks_register_r_table(rducks_runtime_entry_t *runtime, const char *name, SEXP eval_ref,
                                    uint64_t parameter_count, uint64_t chunk_size, char *err, size_t err_cap) {
    rducks_r_table_meta_t *meta = NULL;
    duckdb_table_function fn = NULL;
    duckdb_state rc;

    if (!rducks_allow_calling_thread_r_execution(runtime, err, err_cap)) return false;
    rducks_preserved_release_drain_on_main(runtime);
    if (!runtime || !runtime->connection || !name || !name[0] || !Rf_isFunction(eval_ref)) {
        rducks_format_error_message(err, err_cap, "invalid Rducks table registration request");
        return false;
    }
    if (parameter_count > 64U) {
        rducks_format_error_message(err, err_cap, "Rducks table parameter count must be at most 64");
        return false;
    }
    if (chunk_size < 1U || chunk_size > RDUCKS_TABLE_DEFAULT_CHUNK_SIZE) {
        rducks_format_error_message(err, err_cap, "Rducks table chunk_size must be between 1 and %llu",
                 (unsigned long long)RDUCKS_TABLE_DEFAULT_CHUNK_SIZE);
        return false;
    }

    meta = (rducks_r_table_meta_t *)rducks_calloc_array(1, sizeof(*meta));
    fn = duckdb_create_table_function();
    if (!meta || !fn) {
        rducks_format_error_message(err, err_cap, "failed to allocate DuckDB table function for Rducks table UDF");
        if (fn) duckdb_destroy_table_function(&fn);
        free(meta);
        return false;
    }
    meta->fun = R_NilValue;
    meta->name = rducks_strdup(name);
    if (!meta->name) {
        rducks_format_error_message(err, err_cap, "out of memory copying Rducks table function name");
        duckdb_destroy_table_function(&fn);
        free(meta);
        return false;
    }
    meta->runtime = runtime;
    meta->parameter_count = (idx_t)parameter_count;
    meta->chunk_size = (idx_t)chunk_size;
    R_PreserveObject(eval_ref);
    meta->fun = eval_ref;

    duckdb_table_function_set_name(fn, name);
    if (meta->parameter_count > 0) {
        duckdb_logical_type any_type = duckdb_create_logical_type(DUCKDB_TYPE_ANY);
        if (!any_type) {
            rducks_format_error_message(err, err_cap, "failed to allocate DuckDB ANY argument type for Rducks table function %s", name);
            duckdb_destroy_table_function(&fn);
            rducks_r_table_meta_destroy(meta);
            return false;
        }
        for (idx_t i = 0; i < meta->parameter_count; i++) duckdb_table_function_add_parameter(fn, any_type);
        duckdb_destroy_logical_type(&any_type);
    }
    duckdb_table_function_set_extra_info(fn, meta, rducks_r_table_meta_destroy);
    duckdb_table_function_set_bind(fn, rducks_r_table_bind);
    duckdb_table_function_set_init(fn, rducks_r_table_init);
    duckdb_table_function_set_function(fn, rducks_r_table_function);
    duckdb_table_function_supports_projection_pushdown(fn, true);
    rc = duckdb_register_table_function(runtime->connection, fn);
    duckdb_destroy_table_function(&fn);
    if (rc != DuckDBSuccess) {
        rducks_format_error_message(err, err_cap, "DuckDB failed to register Rducks table function %s", name);
        rducks_r_table_meta_destroy(meta);
        return false;
    }
    return true;
}

static void rducks_register_table_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    duckdb_string_t *names = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 0));
    duckdb_string_t *evaluator_ids = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 1));
    duckdb_string_t *evaluator_tokens = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 2));
    uint64_t *parameter_counts = (uint64_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 3));
    uint64_t *chunk_sizes = (uint64_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(input, 4));
    bool *out = (bool *)duckdb_vector_get_data(output);
    if (!runtime) {
        duckdb_scalar_function_set_error(info, "Rducks runtime is not initialized for this connection");
        return;
    }

    for (idx_t i = 0; i < n; i++) {
        char *name = rducks_copy_duckdb_string(&names[i]);
        char *evaluator_id = rducks_copy_duckdb_string(&evaluator_ids[i]);
        char *evaluator_token = rducks_copy_duckdb_string(&evaluator_tokens[i]);
        char err[RDUCKS_ERROR_BUFFER_SIZE];
        SEXP eval_ref = R_NilValue;
        err[0] = '\0';
        if (!name || !evaluator_id || !evaluator_token) {
            free(name);
            free(evaluator_id);
            free(evaluator_token);
            duckdb_scalar_function_set_error(info, "out of memory");
            return;
        }
        if (!rducks_allow_calling_thread_r_execution(runtime, err, sizeof(err)) ||
            !rducks_lookup_evaluator_ref(evaluator_id, evaluator_token, &eval_ref, err, sizeof(err))) {
            free(name);
            free(evaluator_id);
            free(evaluator_token);
            duckdb_scalar_function_set_error(info, err[0] ? err : "invalid Rducks evaluator handle");
            return;
        }
        out[i] = rducks_register_r_table(runtime, name, eval_ref, parameter_counts[i], chunk_sizes[i], err, sizeof(err));
        free(name);
        free(evaluator_id);
        free(evaluator_token);
        if (!out[i]) {
            duckdb_scalar_function_set_error(info, err[0] ? err : "Rducks table registration failed");
            return;
        }
    }
}
