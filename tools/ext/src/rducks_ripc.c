/* Included by ../rducks_extension.c. RIPC (worker-process) execution over the
 * Quack wire codec. Input and result marshalling use the native
 * DuckDB<->Quack-IR bridge. */


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
        rducks_format_error_message(err_msg, err_cap, "RIPC configure() must return a non-empty character scalar field '%s'", field);
        return 0;
    }
    *out = rducks_strdup_len(CHAR(STRING_ELT(x, 0)), strlen(CHAR(STRING_ELT(x, 0))));
    if (!*out) {
        rducks_format_error_message(err_msg, err_cap, "out of memory copying RIPC configure() field '%s'", field);
        return 0;
    }
    return 1;
}

static int rducks_ripc_configure_meta_on_main(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                              SEXP bundle, char *err_msg, size_t err_cap) {
    SEXP configure = R_NilValue;
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

    if (!runtime || !meta) {
        rducks_format_error_message(err_msg, err_cap, "RIPC metadata is invalid");
        return 0;
    }
    /* Check the recorded main R thread before rducks_ripc_bundle_valid(), which
     * inspects the SEXP bundle and must not touch the R API off-thread. */
    if (!rducks_is_main_thread(runtime)) {
        rducks_format_error_message(err_msg, err_cap, "RIPC configure() must run on the recorded main R thread");
        return 0;
    }
    if (!rducks_ripc_bundle_valid(bundle)) {
        rducks_format_error_message(err_msg, err_cap, "RIPC metadata is invalid");
        return 0;
    }

    configure = rducks_named_list_get(bundle, "configure");
    /* Quack payloads are self-describing, so configure() needs no output schema;
     * its single argument is a vestigial placeholder, so pass NULL. */
    call = PROTECT(Rf_lang2(configure, R_NilValue));
    protect_count++;
    result = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, &r_err));
    protect_count++;
    if (r_err || Rf_inherits(result, "try-error")) {
        const char *detail = NULL;
        if (TYPEOF(result) == STRSXP && XLENGTH(result) > 0 && STRING_ELT(result, 0) != NA_STRING) {
            detail = CHAR(STRING_ELT(result, 0));
        }
        rducks_format_error_message(err_msg, err_cap, "RIPC configure() failed%s%s",
                 (detail && detail[0]) ? ": " : "",
                 (detail && detail[0]) ? detail : "");
        goto fail;
    }
    if (TYPEOF(result) != VECSXP) {
        rducks_format_error_message(err_msg, err_cap, "RIPC configure() must return a named list");
        goto fail;
    }

    endpoints_sexp = rducks_named_list_get(result, "endpoints");
    udf_id_sexp = rducks_named_list_get(result, "udf_id");
    timeout_sexp = rducks_named_list_get(result, "timeout_ms");
    max_pending_sexp = rducks_named_list_get(result, "max_pending");
    external_endpoints_sexp = rducks_named_list_get(result, "external_endpoints");
    if (!Rf_isString(endpoints_sexp) || XLENGTH(endpoints_sexp) < 1) {
        rducks_format_error_message(err_msg, err_cap, "RIPC configure() must return character vector field 'endpoints'");
        goto fail;
    }
    endpoint_count = XLENGTH(endpoints_sexp);
    endpoints = (char **)rducks_calloc_array((size_t)endpoint_count, sizeof(*endpoints));
    if (!endpoints) {
        rducks_format_error_message(err_msg, err_cap, "out of memory copying RIPC endpoints");
        goto fail;
    }
    for (R_xlen_t i = 0; i < endpoint_count; i++) {
        SEXP endpoint = STRING_ELT(endpoints_sexp, i);
        const char *value;
        if (endpoint == NA_STRING || !CHAR(endpoint)[0]) {
            rducks_format_error_message(err_msg, err_cap, "RIPC endpoint %lld is empty", (long long)i + 1LL);
            goto fail;
        }
        value = CHAR(endpoint);
        endpoints[i] = rducks_strdup_len(value, strlen(value));
        if (!endpoints[i]) {
            rducks_format_error_message(err_msg, err_cap, "out of memory copying RIPC endpoint");
            goto fail;
        }
    }
    if (!rducks_ripc_read_string_scalar(udf_id_sexp, "udf_id", &udf_id, err_msg, err_cap)) goto fail;
    if (!Rf_isNull(timeout_sexp)) {
        double timeout_value = Rf_asReal(timeout_sexp);
        if (!R_finite(timeout_value) || timeout_value < 0 || timeout_value > (double)INT_MAX) {
            rducks_format_error_message(err_msg, err_cap, "RIPC timeout_ms must be a non-negative integer-compatible value");
            goto fail;
        }
        timeout_ms = (int)timeout_value;
    }
    if (!Rf_isNull(max_pending_sexp)) {
        double max_pending_value = Rf_asReal(max_pending_sexp);
        if (R_finite(max_pending_value)) {
            if (max_pending_value < 1 || max_pending_value > (double)UINT64_MAX) {
                rducks_format_error_message(err_msg, err_cap, "RIPC max_pending must be a positive integer-compatible value or Inf");
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
                                             int dynamic_payload,
                                             rducks_owned_bytes_t *request,
                                             char *err_msg, size_t err_cap) {
    size_t udf_len;
    size_t total;
    uint8_t *p;
    /* The request payload is either a static declared-type quack chunk or, for
     * dynamic (omitted-args) UDFs, the RDT1 wrapper built by
     * rducks_ripc_build_dynamic_payload (concrete arg tokens + the chunk). The
     * worker dispatches on the payload's leading magic, so the reserved frame
     * field stays zero either way. */
    if (!meta || !meta->ripc_udf_id || !payload || !request) {
        rducks_format_error_message(err_msg, err_cap, "RIPC request metadata is missing");
        return 0;
    }
    udf_len = strlen(meta->ripc_udf_id);
    if (udf_len > UINT32_MAX || row_count > (idx_t)UINT64_MAX || payload_size > (size_t)UINT64_MAX ||
        payload_size > SIZE_MAX - 36U - udf_len) {
        rducks_format_error_message(err_msg, err_cap, "RIPC request is too large");
        return 0;
    }
    total = 36U + udf_len + payload_size;
    request->data = (uint8_t *)malloc(total ? total : 1U);
    if (!request->data) {
        rducks_format_error_message(err_msg, err_cap, "out of memory allocating RIPC request");
        return 0;
    }
    request->size = total;
    p = request->data;
    memcpy(p, "RDK1", 4); p += 4;
    rducks_wire_put_u32(p, 1U); p += 4;
    rducks_wire_put_u32(p, 1U); p += 4;
    rducks_wire_put_u32(p, (uint32_t)udf_len); p += 4;
    rducks_wire_put_u32(p, dynamic_payload ? 1U : 0U); p += 4;   /* reserved: 1 => RDT1 dynamic payload */
    rducks_wire_put_u64(p, (uint64_t)row_count); p += 8;
    rducks_wire_put_u64(p, (uint64_t)payload_size); p += 8;
    if (udf_len) { memcpy(p, meta->ripc_udf_id, udf_len); p += udf_len; }
    if (payload_size) memcpy(p, payload, payload_size);
    return 1;
}

/* Build the RDT1 dynamic-argument payload for an omitted-args (dynamic) UDF:
 *
 *   "RDT1" | count:u32 | wire_len:u64 | (token_len:u32, token bytes) * count | chunk
 *
 * `count` is the bind-resolved arity and the tokens are the concrete argument
 * type tokens (rducks_type_desc_token); the worker
 * (rducks_nng_wire_decode_dynamic_payload) unwraps them so it materializes the
 * chunk under the same effective types DuckDB resolved at bind. All integers are
 * little-endian, matching the R reader. */
static int rducks_ripc_build_dynamic_payload(rducks_r_scalar_meta_t *meta,
                                             const uint8_t *chunk, size_t chunk_size,
                                             rducks_owned_bytes_t *out,
                                             char *err_msg, size_t err_cap) {
    char **tokens;
    size_t *token_lens;
    size_t i, total, tokens_bytes = 0;
    uint8_t *p;
    int ok = 0;
    if (!meta || !meta->args || meta->arity == 0U || !chunk || !out) {
        rducks_format_error_message(err_msg, err_cap, "RIPC dynamic payload requires resolved argument types");
        return 0;
    }
    if (meta->arity > UINT32_MAX || chunk_size > (uint64_t)UINT64_MAX) {
        rducks_format_error_message(err_msg, err_cap, "RIPC dynamic payload is too large");
        return 0;
    }
    tokens = (char **)rducks_calloc_array(meta->arity, sizeof(*tokens));
    token_lens = (size_t *)rducks_calloc_array(meta->arity, sizeof(*token_lens));
    if (!tokens || !token_lens) {
        free(tokens); free(token_lens);
        rducks_format_error_message(err_msg, err_cap, "out of memory allocating RIPC dynamic payload");
        return 0;
    }
    for (i = 0; i < meta->arity; i++) {
        tokens[i] = rducks_type_desc_token(meta->args[i]);
        if (!tokens[i]) {
            rducks_format_error_message(err_msg, err_cap, "out of memory encoding dynamic argument type %zu", i + 1U);
            goto done;
        }
        token_lens[i] = strlen(tokens[i]);
        if (token_lens[i] > UINT32_MAX || tokens_bytes > SIZE_MAX - 4U - token_lens[i]) {
            rducks_format_error_message(err_msg, err_cap, "RIPC dynamic argument type %zu is too large", i + 1U);
            goto done;
        }
        tokens_bytes += 4U + token_lens[i];
    }
    /* magic(4) + count(4) + wire_len(8) + tokens + chunk */
    if (chunk_size > SIZE_MAX - 16U - tokens_bytes) {
        rducks_format_error_message(err_msg, err_cap, "RIPC dynamic payload is too large");
        goto done;
    }
    total = 16U + tokens_bytes + chunk_size;
    out->data = (uint8_t *)malloc(total);
    if (!out->data) {
        rducks_format_error_message(err_msg, err_cap, "out of memory allocating RIPC dynamic payload");
        goto done;
    }
    out->size = total;
    p = out->data;
    memcpy(p, "RDT1", 4); p += 4;
    rducks_wire_put_u32(p, (uint32_t)meta->arity); p += 4;
    rducks_wire_put_u64(p, (uint64_t)chunk_size); p += 8;
    for (i = 0; i < meta->arity; i++) {
        rducks_wire_put_u32(p, (uint32_t)token_lens[i]); p += 4;
        if (token_lens[i]) { memcpy(p, tokens[i], token_lens[i]); p += token_lens[i]; }
    }
    if (chunk_size) memcpy(p, chunk, chunk_size);
    ok = 1;
done:
    for (i = 0; i < meta->arity; i++) free(tokens[i]);
    free(tokens);
    free(token_lens);
    return ok;
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
        rducks_format_error_message(err_msg, err_cap, "invalid RIPC response frame");
        return 0;
    }
    p = response + 4;
    version = rducks_wire_get_u32(p); p += 4;
    type = rducks_wire_get_u32(p); p += 4;
    status = rducks_wire_get_u32(p); p += 4;
    error_len = rducks_wire_get_u32(p); p += 4;
    reserved = rducks_wire_get_u32(p); p += 4;
    payload_len = rducks_wire_get_u64(p); p += 8;
    if (version != 1U || type != 100U) {
        rducks_format_error_message(err_msg, err_cap, "unsupported RIPC response frame");
        return 0;
    }
    /* Match the R-side frame validation: status is a 0/1 flag and reserved must
     * be zero. Reject anything else rather than treating it loosely. */
    if (reserved != 0U || status > 1U) {
        rducks_format_error_message(err_msg, err_cap, "malformed RIPC response frame header");
        return 0;
    }
    if (payload_len > (uint64_t)SIZE_MAX || (size_t)payload_len > SIZE_MAX - 32U - (size_t)error_len) {
        rducks_format_error_message(err_msg, err_cap, "RIPC response is too large");
        return 0;
    }
    total = 32U + (size_t)error_len + (size_t)payload_len;
    if (total != response_size) {
        rducks_format_error_message(err_msg, err_cap, "truncated RIPC response frame");
        return 0;
    }
    if (status != 0U) {
        size_t n = (size_t)error_len;
        if (n >= err_cap) n = err_cap ? err_cap - 1U : 0U;
        if (err_cap > 0U) {
            if (n > 0U) memcpy(err_msg, p, n);
            err_msg[n] = '\0';
        }
        if (err_cap > 0U && err_msg[0] == '\0') rducks_format_error_message(err_msg, err_cap, "RIPC worker returned an error");
        return 0;
    }
    p += error_len;
    *payload_out = p;
    *payload_size_out = (size_t)payload_len;
    return 1;
}


/* ---- DuckDB <-> Quack-IR bridge for the RIPC worker boundary ----
 * Pure C (runs off the recorded R thread). Handles fixed-width scalars, decimal
 * and enum storage, varchar/blob/bit, GEOMETRY (as opaque physical bytes via a
 * BLOB column), and the LIST/ARRAY/STRUCT/MAP/UNION containers (recursively, over
 * supported leaf types; MAP as LIST(STRUCT(key,value)), UNION as the physical
 * STRUCT(tag,members)). VARIANT is not yet supported on the wire path and fails
 * cleanly via build_type. The Quack IR is a DuckDB DataChunk subset, so the
 * fixed-width and validity copies are direct. */

static rdx_qk_type *rducks_quack_build_type(const rducks_type_desc_t *desc) {
    uint32_t id = 0U;
    if (!desc) return NULL;
    if (desc->kind == RDUCKS_KIND_DECIMAL) {
        rdx_qk_type *t = rdx_qk_type_new(RDX_QK_LTYPE_DECIMAL);
        if (t) {
            t->width = desc->decimal_width;
            t->scale = desc->decimal_scale;
        }
        return t;
    }
    if (desc->kind == RDUCKS_KIND_ENUM) {
        /* The enum dictionary is carried in the desc as field_names; build a
         * wire ENUM type with the same labels so the worker reconstructs
         * rducks_enum values. The physical index (0-based, width chosen from the
         * dictionary size) matches DuckDB's enum internal storage, so the
         * fixed-width copy path transports it. */
        rdx_qk_type *t = rdx_qk_type_new(RDX_QK_LTYPE_ENUM);
        if (!t) return NULL;
        if (desc->field_count > 0) {
            if (!rdx_qk_type_set_enum_labels(t, (const char *const *)desc->field_names,
                                             (uint32_t)desc->field_count)) {
                rdx_qk_type_free(t);
                return NULL;
            }
        }
        return t;
    }
    if (desc->kind == RDUCKS_KIND_STRUCT) {
        rdx_qk_type *t = rdx_qk_type_new(RDX_QK_LTYPE_STRUCT);
        size_t f;
        if (!t) return NULL;
        for (f = 0; f < desc->field_count; f++) {
            rdx_qk_type *child = rducks_quack_build_type(desc->field_types[f]);
            const char *fname = desc->field_names ? desc->field_names[f] : NULL;
            if (!child || !rdx_qk_type_add_child(t, child, fname)) {
                if (child) rdx_qk_type_free(child);
                rdx_qk_type_free(t);
                return NULL;
            }
        }
        return t;
    }
    if (desc->kind == RDUCKS_KIND_LIST || desc->kind == RDUCKS_KIND_ARRAY) {
        rdx_qk_type *t = rdx_qk_type_new(desc->kind == RDUCKS_KIND_LIST
                                             ? RDX_QK_LTYPE_LIST : RDX_QK_LTYPE_ARRAY);
        rdx_qk_type *child;
        if (!t) return NULL;
        if (desc->kind == RDUCKS_KIND_ARRAY) t->array_size = (uint32_t)desc->array_size;
        child = rducks_quack_build_type(desc->child);
        /* The wire decoder names the single list/array child "child"; match it so
         * the returned-type validation in the result path compares equal. */
        if (!child || !rdx_qk_type_add_child(t, child, "child")) {
            if (child) rdx_qk_type_free(child);
            rdx_qk_type_free(t);
            return NULL;
        }
        return t;
    }
    if (desc->kind == RDUCKS_KIND_MAP) {
        /* MAP rides the wire as LIST(STRUCT(key, value)), matching DuckDB's
         * physical layout. The single list child is the key/value entry struct. */
        rdx_qk_type *t = rdx_qk_type_new(RDX_QK_LTYPE_MAP);
        rdx_qk_type *entry, *kt, *vt;
        if (!t) return NULL;
        entry = rdx_qk_type_new(RDX_QK_LTYPE_STRUCT);
        if (!entry) { rdx_qk_type_free(t); return NULL; }
        kt = rducks_quack_build_type(desc->key);
        if (!kt || !rdx_qk_type_add_child(entry, kt, "key")) {
            if (kt) rdx_qk_type_free(kt);
            rdx_qk_type_free(entry); rdx_qk_type_free(t);
            return NULL;
        }
        vt = rducks_quack_build_type(desc->value);
        if (!vt || !rdx_qk_type_add_child(entry, vt, "value")) {
            if (vt) rdx_qk_type_free(vt);
            rdx_qk_type_free(entry); rdx_qk_type_free(t);
            return NULL;
        }
        if (!rdx_qk_type_add_child(t, entry, "child")) {
            rdx_qk_type_free(entry); rdx_qk_type_free(t);
            return NULL;
        }
        return t;
    }
    if (desc->kind == RDUCKS_KIND_UNION) {
        /* DuckDB stores UNION physically as STRUCT(tag UTINYINT, member0, ...).
         * Transport it as that struct so the active member tag is explicit and an
         * active-but-NULL member is not confused with an inactive one. */
        rdx_qk_type *t = rdx_qk_type_new(RDX_QK_LTYPE_STRUCT);
        rdx_qk_type *tag;
        size_t f;
        if (!t) return NULL;
        tag = rdx_qk_type_new(RDX_QK_LTYPE_UTINYINT);
        if (!tag || !rdx_qk_type_add_child(t, tag, "")) {
            if (tag) rdx_qk_type_free(tag);
            rdx_qk_type_free(t);
            return NULL;
        }
        for (f = 0; f < desc->field_count; f++) {
            rdx_qk_type *m = rducks_quack_build_type(desc->field_types[f]);
            const char *mn = desc->field_names ? desc->field_names[f] : NULL;
            if (!m || !rdx_qk_type_add_child(t, m, mn)) {
                if (m) rdx_qk_type_free(m);
                rdx_qk_type_free(t);
                return NULL;
            }
        }
        return t;
    }
    if (desc->kind != RDUCKS_KIND_SCALAR) return NULL;
    switch (desc->scalar) {
    case RDUCKS_TYPE_BOOL: id = RDX_QK_LTYPE_BOOLEAN; break;
    case RDUCKS_TYPE_I8: id = RDX_QK_LTYPE_TINYINT; break;
    case RDUCKS_TYPE_U8: id = RDX_QK_LTYPE_UTINYINT; break;
    case RDUCKS_TYPE_I16: id = RDX_QK_LTYPE_SMALLINT; break;
    case RDUCKS_TYPE_U16: id = RDX_QK_LTYPE_USMALLINT; break;
    case RDUCKS_TYPE_I32: id = RDX_QK_LTYPE_INTEGER; break;
    case RDUCKS_TYPE_U32: id = RDX_QK_LTYPE_UINTEGER; break;
    case RDUCKS_TYPE_I64: id = RDX_QK_LTYPE_BIGINT; break;
    case RDUCKS_TYPE_U64: id = RDX_QK_LTYPE_UBIGINT; break;
    case RDUCKS_TYPE_F32: id = RDX_QK_LTYPE_FLOAT; break;
    case RDUCKS_TYPE_F64: id = RDX_QK_LTYPE_DOUBLE; break;
    case RDUCKS_TYPE_DATE: id = RDX_QK_LTYPE_DATE; break;
    case RDUCKS_TYPE_TIME: id = RDX_QK_LTYPE_TIME; break;
    case RDUCKS_TYPE_TIMESTAMP: id = RDX_QK_LTYPE_TIMESTAMP; break;
    case RDUCKS_TYPE_HUGEINT: id = RDX_QK_LTYPE_HUGEINT; break;
    case RDUCKS_TYPE_UHUGEINT: id = RDX_QK_LTYPE_UHUGEINT; break;
    case RDUCKS_TYPE_UUID: id = RDX_QK_LTYPE_UUID; break;
    case RDUCKS_TYPE_INTERVAL: id = RDX_QK_LTYPE_INTERVAL; break;
    case RDUCKS_TYPE_VARCHAR: id = RDX_QK_LTYPE_VARCHAR; break;
    case RDUCKS_TYPE_BLOB: id = RDX_QK_LTYPE_BLOB; break;
    case RDUCKS_TYPE_BIT: id = RDX_QK_LTYPE_BIT; break;
    /* GEOMETRY is physically a varlen blob (WKB bytes). It rides the wire as a
     * BLOB column; the worker reconstructs geometry from its declared type. */
    case RDUCKS_TYPE_GEOMETRY: id = RDX_QK_LTYPE_BLOB; break;
    default: return NULL;
    }
    return rdx_qk_type_new(id);
}

static int rducks_quack_is_varlen(const rducks_type_desc_t *desc) {
    return desc && desc->kind == RDUCKS_KIND_SCALAR &&
           (desc->scalar == RDUCKS_TYPE_VARCHAR || desc->scalar == RDUCKS_TYPE_BLOB ||
            desc->scalar == RDUCKS_TYPE_BIT || desc->scalar == RDUCKS_TYPE_GEOMETRY);
}

static rdx_qk_vector *rducks_quack_vector_from_duckdb(const rdx_qk_type *t, const rducks_type_desc_t *desc,
                                                      duckdb_vector vec, idx_t rows, char *err, size_t cap) {
    rdx_qk_vector *v = rdx_qk_vector_new(t, (uint64_t)rows);
    uint64_t *validity;
    if (!v) {
        rducks_format_error_message(err, cap, "out of memory allocating Rducks wire vector");
        return NULL;
    }
    validity = duckdb_vector_get_validity(vec);
    if (validity && rows > 0) {
        size_t mask_bytes = (size_t)((rows + 63) / 64) * 8U;
        if (!rdx_qk_vector_alloc_validity(v)) {
            rdx_qk_vector_free(v);
            rducks_format_error_message(err, cap, "out of memory allocating Rducks wire validity");
            return NULL;
        }
        memcpy(v->validity, validity, mask_bytes);
    }
    if (desc->kind == RDUCKS_KIND_STRUCT) {
        size_t f;
        v->nchildren = (uint32_t)desc->field_count;
        v->children = (rdx_qk_vector **)calloc(desc->field_count ? desc->field_count : 1,
                                               sizeof(*v->children));
        if (!v->children) {
            rdx_qk_vector_free(v);
            rducks_format_error_message(err, cap, "out of memory allocating Rducks wire struct children");
            return NULL;
        }
        for (f = 0; f < desc->field_count; f++) {
            duckdb_vector cv = duckdb_struct_vector_get_child(vec, (idx_t)f);
            v->children[f] = rducks_quack_vector_from_duckdb(t->children[f], desc->field_types[f],
                                                            cv, rows, err, cap);
            if (!v->children[f]) {
                rdx_qk_vector_free(v);
                return NULL;
            }
        }
        return v;
    }
    if (desc->kind == RDUCKS_KIND_LIST || desc->kind == RDUCKS_KIND_ARRAY) {
        duckdb_vector cv;
        idx_t child_rows;
        if (desc->kind == RDUCKS_KIND_LIST) {
            duckdb_list_entry *entries = (duckdb_list_entry *)duckdb_vector_get_data(vec);
            idx_t full_size = duckdb_list_vector_get_size(vec);
            uint64_t max_extent = 0;
            idx_t r;
            cv = duckdb_list_vector_get_child(vec);
            /* Only marshal the child rows actually referenced by valid entries
             * (max offset+length), not the full child vector, which may carry
             * trailing slack. Reject (do not clamp) any entry whose range falls
             * outside the child vector; the bound is overflow-safe. */
            for (r = 0; r < rows; r++) {
                uint64_t off, len;
                if (validity && !duckdb_validity_row_is_valid(validity, r)) continue;
                off = entries[r].offset;
                len = entries[r].length;
                if (off > (uint64_t)full_size || len > (uint64_t)full_size - off) {
                    rdx_qk_vector_free(v);
                    rducks_format_error_message(err, cap, "DuckDB list entry references rows beyond the child vector");
                    return NULL;
                }
                if (off + len > max_extent) max_extent = off + len;
            }
            child_rows = (idx_t)max_extent;
            if (!rdx_qk_vector_alloc_list(v, max_extent)) {
                rdx_qk_vector_free(v);
                rducks_format_error_message(err, cap, "out of memory allocating Rducks wire list offsets");
                return NULL;
            }
            for (r = 0; r < rows; r++) {
                /* Zero the offset/length of invalid (NULL) list rows: DuckDB may
                 * leave arbitrary values there, and a downstream consumer that
                 * sizes the child from offset+length must not see garbage. */
                if (validity && !duckdb_validity_row_is_valid(validity, r)) {
                    v->list_offsets[r] = 0;
                    v->list_lengths[r] = 0;
                } else {
                    v->list_offsets[r] = entries[r].offset;
                    v->list_lengths[r] = entries[r].length;
                }
            }
        } else {
            cv = duckdb_array_vector_get_child(vec);
            child_rows = rows * (idx_t)desc->array_size;
        }
        v->nchildren = 1;
        v->children = (rdx_qk_vector **)calloc(1, sizeof(*v->children));
        if (!v->children) {
            rdx_qk_vector_free(v);
            rducks_format_error_message(err, cap, "out of memory allocating Rducks wire list child");
            return NULL;
        }
        v->children[0] = rducks_quack_vector_from_duckdb(t->children[0], desc->child, cv, child_rows, err, cap);
        if (!v->children[0]) {
            rdx_qk_vector_free(v);
            return NULL;
        }
        return v;
    }
    if (desc->kind == RDUCKS_KIND_MAP) {
        /* DuckDB MAP is physically LIST(STRUCT(key, value)). Marshal it as a list
         * whose single child is the key/value entry struct. */
        duckdb_list_entry *entries = (duckdb_list_entry *)duckdb_vector_get_data(vec);
        idx_t full_size = duckdb_list_vector_get_size(vec);
        duckdb_vector struct_child = duckdb_list_vector_get_child(vec);
        const rdx_qk_type *entry_type = t->children[0];
        uint64_t max_extent = 0;
        idx_t r;
        rdx_qk_vector *entry;
        uint64_t *struct_validity;
        for (r = 0; r < rows; r++) {
            uint64_t off, len;
            if (validity && !duckdb_validity_row_is_valid(validity, r)) continue;
            off = entries[r].offset;
            len = entries[r].length;
            if (off > (uint64_t)full_size || len > (uint64_t)full_size - off) {
                rdx_qk_vector_free(v);
                rducks_format_error_message(err, cap, "DuckDB map entry references rows beyond the child vector");
                return NULL;
            }
            if (off + len > max_extent) max_extent = off + len;
        }
        if (!rdx_qk_vector_alloc_list(v, max_extent)) {
            rdx_qk_vector_free(v);
            rducks_format_error_message(err, cap, "out of memory allocating Rducks wire map offsets");
            return NULL;
        }
        for (r = 0; r < rows; r++) {
            if (validity && !duckdb_validity_row_is_valid(validity, r)) {
                v->list_offsets[r] = 0;
                v->list_lengths[r] = 0;
            } else {
                v->list_offsets[r] = entries[r].offset;
                v->list_lengths[r] = entries[r].length;
            }
        }
        entry = rdx_qk_vector_new(entry_type, max_extent);
        if (!entry) {
            rdx_qk_vector_free(v);
            rducks_format_error_message(err, cap, "out of memory allocating Rducks wire map entry");
            return NULL;
        }
        struct_validity = duckdb_vector_get_validity(struct_child);
        if (struct_validity && max_extent > 0) {
            size_t mask_bytes = (size_t)((max_extent + 63) / 64) * 8U;
            if (!rdx_qk_vector_alloc_validity(entry)) {
                rdx_qk_vector_free(entry); rdx_qk_vector_free(v);
                rducks_format_error_message(err, cap, "out of memory allocating Rducks wire map entry validity");
                return NULL;
            }
            memcpy(entry->validity, struct_validity, mask_bytes);
        }
        entry->nchildren = 2;
        entry->children = (rdx_qk_vector **)calloc(2, sizeof(*entry->children));
        if (!entry->children) {
            rdx_qk_vector_free(entry); rdx_qk_vector_free(v);
            rducks_format_error_message(err, cap, "out of memory allocating Rducks wire map entry children");
            return NULL;
        }
        entry->children[0] = rducks_quack_vector_from_duckdb(entry_type->children[0], desc->key,
                                                            duckdb_struct_vector_get_child(struct_child, 0),
                                                            (idx_t)max_extent, err, cap);
        if (!entry->children[0]) { rdx_qk_vector_free(entry); rdx_qk_vector_free(v); return NULL; }
        entry->children[1] = rducks_quack_vector_from_duckdb(entry_type->children[1], desc->value,
                                                            duckdb_struct_vector_get_child(struct_child, 1),
                                                            (idx_t)max_extent, err, cap);
        if (!entry->children[1]) { rdx_qk_vector_free(entry); rdx_qk_vector_free(v); return NULL; }
        v->nchildren = 1;
        v->children = (rdx_qk_vector **)calloc(1, sizeof(*v->children));
        if (!v->children) {
            rdx_qk_vector_free(entry); rdx_qk_vector_free(v);
            rducks_format_error_message(err, cap, "out of memory allocating Rducks wire map child");
            return NULL;
        }
        v->children[0] = entry;
        return v;
    }
    if (desc->kind == RDUCKS_KIND_UNION) {
        /* DuckDB UNION is physically STRUCT(tag, member0, ...). Read it as that
         * struct: child 0 is the UTINYINT tag, children 1..n are the members. */
        rducks_type_desc_t tag_desc;
        size_t f;
        memset(&tag_desc, 0, sizeof(tag_desc));
        tag_desc.kind = RDUCKS_KIND_SCALAR;
        tag_desc.scalar = RDUCKS_TYPE_U8;
        v->nchildren = (uint32_t)(desc->field_count + 1U);
        v->children = (rdx_qk_vector **)calloc(desc->field_count + 1U, sizeof(*v->children));
        if (!v->children) {
            rdx_qk_vector_free(v);
            rducks_format_error_message(err, cap, "out of memory allocating Rducks wire union children");
            return NULL;
        }
        v->children[0] = rducks_quack_vector_from_duckdb(t->children[0], &tag_desc,
                                                        duckdb_struct_vector_get_child(vec, 0), rows, err, cap);
        if (!v->children[0]) { rdx_qk_vector_free(v); return NULL; }
        for (f = 0; f < desc->field_count; f++) {
            v->children[f + 1U] = rducks_quack_vector_from_duckdb(t->children[f + 1U], desc->field_types[f],
                                                                 duckdb_struct_vector_get_child(vec, (idx_t)(f + 1U)),
                                                                 rows, err, cap);
            if (!v->children[f + 1U]) { rdx_qk_vector_free(v); return NULL; }
        }
        return v;
    }
    if (rducks_quack_is_varlen(desc)) {
        duckdb_string_t *strs = (duckdb_string_t *)duckdb_vector_get_data(vec);
        size_t pool = 0U;
        size_t fill = 0U;
        idx_t r;
        for (r = 0; r < rows; r++) {
            if (validity && !duckdb_validity_row_is_valid(validity, r)) continue;
            pool += duckdb_string_t_length(strs[r]);
        }
        if (!rdx_qk_vector_alloc_strings(v, pool)) {
            rdx_qk_vector_free(v);
            rducks_format_error_message(err, cap, "out of memory allocating Rducks wire string pool");
            return NULL;
        }
        for (r = 0; r < rows; r++) {
            v->str_offsets[r] = fill;
            if (!(validity && !duckdb_validity_row_is_valid(validity, r))) {
                uint32_t len = duckdb_string_t_length(strs[r]);
                if (len) {
                    memcpy(v->str_pool + fill, duckdb_string_t_data(&strs[r]), len);
                    fill += len;
                }
            }
        }
        v->str_offsets[rows] = fill;
        v->str_pool_size = fill;
    } else {
        size_t width = rdx_qk_type_fixed_width(t);
        if (width == 0U) {
            rdx_qk_vector_free(v);
            rducks_format_error_message(err, cap, "unsupported Rducks wire input type");
            return NULL;
        }
        if (!rdx_qk_vector_alloc_fixed(v)) {
            rdx_qk_vector_free(v);
            rducks_format_error_message(err, cap, "out of memory allocating Rducks wire payload");
            return NULL;
        }
        if (rows > 0) memcpy(v->data, duckdb_vector_get_data(vec), width * (size_t)rows);
    }
    return v;
}

static int rducks_quack_encode_input_chunk_native(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                                  duckdb_data_chunk input, rducks_owned_bytes_t *payload,
                                                  char *err, size_t cap) {
    idx_t n = duckdb_data_chunk_get_size(input);
    size_t ncol = meta->arity;
    rdx_qk_chunk *chunk;
    rdx_qk_writer w;
    rdx_qk_error qerr;
    uint8_t *bytes;
    size_t nbytes;
    (void)runtime;
    if (ncol > 0xffffffffU) {
        rducks_format_error_message(err, cap, "Rducks wire input has too many columns");
        return 0;
    }
    chunk = rdx_qk_chunk_new((uint64_t)n, (uint32_t)ncol);
    if (!chunk) {
        rducks_format_error_message(err, cap, "out of memory allocating Rducks wire chunk");
        return 0;
    }
    for (size_t c = 0; c < ncol; c++) {
        rdx_qk_type *t = rducks_quack_build_type(meta->args[c]);
        if (!t) {
            rdx_qk_chunk_free(chunk);
            rducks_format_error_message(err, cap, "unsupported Rducks wire input type for argument %zu", c + 1U);
            return 0;
        }
        chunk->types[c] = t;
        chunk->columns[c] = rducks_quack_vector_from_duckdb(t, meta->args[c],
                                                            duckdb_data_chunk_get_vector(input, (idx_t)c),
                                                            n, err, cap);
        if (!chunk->columns[c]) {
            rdx_qk_chunk_free(chunk);
            return 0;
        }
    }
    rdx_qk_writer_init(&w);
    memset(&qerr, 0, sizeof(qerr));
    if (!rdx_qk_chunk_encode(&w, chunk, &qerr)) {
        rdx_qk_writer_destroy(&w);
        rdx_qk_chunk_free(chunk);
        rducks_format_error_message(err, cap, "Rducks wire encode failed: %s", qerr.message[0] ? qerr.message : "unknown error");
        return 0;
    }
    bytes = rdx_qk_writer_detach(&w, &nbytes);
    rdx_qk_writer_destroy(&w);
    rdx_qk_chunk_free(chunk);
    if (!bytes) {
        rducks_format_error_message(err, cap, "out of memory detaching Rducks wire payload");
        return 0;
    }
    payload->data = bytes;
    payload->size = nbytes;
    return 1;
}

static void rducks_quack_copy_validity_out(const rdx_qk_vector *v, duckdb_vector out, idx_t n) {
    if (v->has_validity) {
        size_t mask_bytes = (size_t)((n + 63) / 64) * 8U;
        uint64_t *out_validity;
        duckdb_vector_ensure_validity_writable(out);
        out_validity = duckdb_vector_get_validity(out);
        if (out_validity && v->validity) memcpy(out_validity, v->validity, mask_bytes);
    }
}

static int rducks_quack_write_vector_to_duckdb(const rdx_qk_vector *v, const rducks_type_desc_t *desc,
                                               duckdb_vector out, idx_t n, char *err, size_t cap) {
    if (desc->kind == RDUCKS_KIND_STRUCT) {
        size_t f;
        if (v->nchildren != (uint32_t)desc->field_count) {
            rducks_format_error_message(err, cap, "Rducks wire struct result has the wrong field count");
            return 0;
        }
        rducks_quack_copy_validity_out(v, out, n);
        for (f = 0; f < desc->field_count; f++) {
            duckdb_vector cv = duckdb_struct_vector_get_child(out, (idx_t)f);
            if (!rducks_quack_write_vector_to_duckdb(v->children[f], desc->field_types[f], cv, n, err, cap)) {
                return 0;
            }
        }
        return 1;
    }
    if (desc->kind == RDUCKS_KIND_LIST || desc->kind == RDUCKS_KIND_ARRAY) {
        idx_t total;
        duckdb_vector cv;
        if (v->nchildren != 1 || !v->children || !v->children[0]) {
            rducks_format_error_message(err, cap, "Rducks wire list result is missing its child");
            return 0;
        }
        total = (idx_t)v->children[0]->rows;
        rducks_quack_copy_validity_out(v, out, n);
        if (desc->kind == RDUCKS_KIND_LIST) {
            duckdb_list_entry *entries;
            idx_t r;
            if (duckdb_list_vector_reserve(out, total) != DuckDBSuccess ||
                duckdb_list_vector_set_size(out, total) != DuckDBSuccess) {
                rducks_format_error_message(err, cap, "Rducks wire list result could not size the child vector");
                return 0;
            }
            entries = (duckdb_list_entry *)duckdb_vector_get_data(out);
            for (r = 0; r < n; r++) {
                entries[r].offset = v->list_offsets ? v->list_offsets[r] : 0;
                entries[r].length = v->list_lengths ? v->list_lengths[r] : 0;
            }
            cv = duckdb_list_vector_get_child(out);
        } else {
            if (total != n * (idx_t)desc->array_size) {
                rducks_format_error_message(err, cap, "Rducks wire array result child length mismatch");
                return 0;
            }
            cv = duckdb_array_vector_get_child(out);
        }
        return rducks_quack_write_vector_to_duckdb(v->children[0], desc->child, cv, total, err, cap);
    }
    if (desc->kind == RDUCKS_KIND_MAP) {
        /* Write back as LIST(STRUCT(key, value)): size the entry struct child,
         * write the per-row entries, then the key and value member vectors. */
        rdx_qk_vector *entry;
        duckdb_vector struct_child;
        duckdb_list_entry *entries;
        idx_t total, r;
        if (v->nchildren != 1 || !v->children || !v->children[0] ||
            v->children[0]->nchildren != 2 || !v->children[0]->children ||
            !v->children[0]->children[0] || !v->children[0]->children[1]) {
            rducks_format_error_message(err, cap, "Rducks wire map result is missing its key/value child");
            return 0;
        }
        entry = v->children[0];
        total = (idx_t)entry->rows;
        rducks_quack_copy_validity_out(v, out, n);
        if (duckdb_list_vector_reserve(out, total) != DuckDBSuccess ||
            duckdb_list_vector_set_size(out, total) != DuckDBSuccess) {
            rducks_format_error_message(err, cap, "Rducks wire map result could not size the entry vector");
            return 0;
        }
        entries = (duckdb_list_entry *)duckdb_vector_get_data(out);
        for (r = 0; r < n; r++) {
            entries[r].offset = v->list_offsets ? v->list_offsets[r] : 0;
            entries[r].length = v->list_lengths ? v->list_lengths[r] : 0;
        }
        struct_child = duckdb_list_vector_get_child(out);
        if (entry->has_validity) rducks_quack_copy_validity_out(entry, struct_child, total);
        if (!rducks_quack_write_vector_to_duckdb(entry->children[0], desc->key,
                                                 duckdb_struct_vector_get_child(struct_child, 0), total, err, cap)) {
            return 0;
        }
        if (!rducks_quack_write_vector_to_duckdb(entry->children[1], desc->value,
                                                 duckdb_struct_vector_get_child(struct_child, 1), total, err, cap)) {
            return 0;
        }
        return 1;
    }
    if (desc->kind == RDUCKS_KIND_UNION) {
        /* Write back to the physical STRUCT(tag, member0, ...) union layout. */
        rducks_type_desc_t tag_desc;
        size_t f;
        if (v->nchildren != (uint32_t)(desc->field_count + 1U)) {
            rducks_format_error_message(err, cap, "Rducks wire union result has the wrong member count");
            return 0;
        }
        memset(&tag_desc, 0, sizeof(tag_desc));
        tag_desc.kind = RDUCKS_KIND_SCALAR;
        tag_desc.scalar = RDUCKS_TYPE_U8;
        /* Validate every active tag is an existing member before writing into the
         * DuckDB union. A buggy or external worker could return a tag past the
         * member count (type equality alone cannot catch it: the tag column is
         * just UTINYINT), which would index a non-existent union member. */
        {
            const rdx_qk_vector *tag = v->children[0];
            idx_t r;
            if (tag->type && rdx_qk_type_fixed_width(tag->type) == 1U && tag->data) {
                const uint8_t *codes = (const uint8_t *)tag->data;
                for (r = 0; r < n; r++) {
                    if (tag->has_validity && !rdx_qk_vector_row_is_valid(tag, r)) continue;
                    if ((size_t)codes[r] >= desc->field_count) {
                        rducks_format_error_message(err, cap, "RIPC union result tag is out of range");
                        return 0;
                    }
                }
            }
        }
        rducks_quack_copy_validity_out(v, out, n);
        if (!rducks_quack_write_vector_to_duckdb(v->children[0], &tag_desc,
                                                 duckdb_struct_vector_get_child(out, 0), n, err, cap)) {
            return 0;
        }
        for (f = 0; f < desc->field_count; f++) {
            if (!rducks_quack_write_vector_to_duckdb(v->children[f + 1U], desc->field_types[f],
                                                     duckdb_struct_vector_get_child(out, (idx_t)(f + 1U)), n, err, cap)) {
                return 0;
            }
        }
        return 1;
    }
    if (desc->kind == RDUCKS_KIND_ENUM) {
        /* Validate every active enum index is within the declared dictionary
         * before the fixed-width copy below writes it into the DuckDB enum
         * vector. Like the union tag, type equality cannot catch this (the codes
         * ride as a plain unsigned integer), and an out-of-range index would make
         * DuckDB read past its enum dictionary. */
        size_t w = v->type ? rdx_qk_type_fixed_width(v->type) : 0U;
        if (w && v->data) {
            idx_t r;
            for (r = 0; r < n; r++) {
                uint32_t code;
                if (v->has_validity && !rdx_qk_vector_row_is_valid(v, r)) continue;
                if (w == 1U) code = ((const uint8_t *)v->data)[r];
                else if (w == 2U) { uint16_t c16; memcpy(&c16, (const uint8_t *)v->data + 2U * r, 2); code = c16; }
                else { uint32_t c32; memcpy(&c32, (const uint8_t *)v->data + 4U * r, 4); code = c32; }
                if ((size_t)code >= desc->field_count) {
                    rducks_format_error_message(err, cap, "RIPC enum result index is out of range");
                    return 0;
                }
            }
        }
    }
    if (rducks_quack_is_varlen(desc)) {
        uint64_t *out_validity = NULL;
        idx_t r;
        if (v->has_validity) {
            duckdb_vector_ensure_validity_writable(out);
            out_validity = duckdb_vector_get_validity(out);
        }
        for (r = 0; r < n; r++) {
            if (v->has_validity && !rdx_qk_vector_row_is_valid(v, r)) {
                if (out_validity) duckdb_validity_set_row_invalid(out_validity, r);
                continue;
            }
            {
                uint64_t start = v->str_offsets[r];
                uint64_t end = v->str_offsets[r + 1];
                duckdb_vector_assign_string_element_len(out, r, (const char *)(v->str_pool + start), (idx_t)(end - start));
            }
        }
    } else {
        size_t width = v->type ? rdx_qk_type_fixed_width(v->type) : 0U;
        if (width == 0U) {
            rducks_format_error_message(err, cap, "unsupported Rducks wire result type");
            return 0;
        }
        if (n > 0 && v->data) memcpy(duckdb_vector_get_data(out), v->data, width * (size_t)n);
        if (v->has_validity) {
            size_t mask_bytes = (size_t)((n + 63) / 64) * 8U;
            uint64_t *out_validity;
            duckdb_vector_ensure_validity_writable(out);
            out_validity = duckdb_vector_get_validity(out);
            if (out_validity) memcpy(out_validity, v->validity, mask_bytes);
        }
    }
    return 1;
}

static int rducks_quack_decode_result_to_vector(rducks_runtime_entry_t *runtime, const uint8_t *payload, size_t size,
                                                rducks_type_desc_t *return_desc, idx_t n, duckdb_vector output,
                                                char *err, size_t cap) {
    rdx_qk_reader rd;
    rdx_qk_chunk *chunk = NULL;
    rdx_qk_error qerr;
    int ok = 0;
    (void)runtime;
    if (!payload || size == 0U) {
        rducks_format_error_message(err, cap, "RIPC worker returned an empty wire payload");
        return 0;
    }
    rdx_qk_reader_init(&rd, payload, size);
    memset(&qerr, 0, sizeof(qerr));
    if (!rdx_qk_chunk_decode(&rd, &chunk, &qerr)) {
        rducks_format_error_message(err, cap, "Rducks wire decode failed: %s", qerr.message[0] ? qerr.message : "unknown error");
        return 0;
    }
    if (chunk->ncolumns != 1U || chunk->rows != (uint64_t)n) {
        rducks_format_error_message(err, cap, "RIPC result shape does not match the expected output");
        goto done;
    }
    {
        /* Validate the worker's returned wire type against the declared return
         * type before writing bytes into DuckDB, so a mismatched/buggy worker
         * cannot drive the varlen write path with the wrong vector layout. */
        rdx_qk_type *expected = rducks_quack_build_type(return_desc);
        int type_ok = expected && chunk->columns[0] &&
                      rdx_qk_type_equal(expected, chunk->columns[0]->type);
        if (expected) rdx_qk_type_free(expected);
        if (!type_ok) {
            rducks_format_error_message(err, cap, "RIPC worker returned a wire type that does not match the declared return type");
            goto done;
        }
    }
    if (!rducks_quack_write_vector_to_duckdb(chunk->columns[0], return_desc, output, n, err, cap)) goto done;
    ok = 1;
done:
    rdx_qk_chunk_free(chunk);
    return ok;
}

static rducks_nng_client_pool_t *
rducks_ripc_acquire_pool(rducks_r_scalar_meta_t *meta, char *err_msg, size_t err_cap) {
    rducks_nng_client_pool_t *pool = NULL;

    if (!meta) {
        if (err_msg && err_cap) rducks_format_error_message(err_msg, err_cap, "RIPC execution metadata is missing");
        return NULL;
    }

    rducks_runtime_lock();
    pool = meta->ripc_client_pool;
    if (!rducks_nng_client_pool_acquire(pool, err_msg, err_cap)) {
        rducks_runtime_unlock();
        return NULL;
    }
    rducks_runtime_unlock();
    return pool;
}

static int rducks_ripc_execute(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                               duckdb_data_chunk input, duckdb_vector output,
                               char *err_msg, size_t err_cap) {
    idx_t n;
    rducks_nng_client_pool_t *client_pool = NULL;
    rducks_owned_bytes_t input_payload = {0};
    rducks_owned_bytes_t dynamic_payload = {0};
    rducks_owned_bytes_t request = {0};
    const uint8_t *request_payload;
    size_t request_payload_size;
    void *response_msg = NULL;
    const uint8_t *response = NULL;
    size_t response_size = 0;
    const uint8_t *result_payload = NULL;
    size_t result_payload_size = 0;
    int ok = 0;

    if (!runtime || !meta) {
        rducks_format_error_message(err_msg, err_cap, "RIPC execution metadata is missing");
        return 0;
    }
    if (!meta->ripc_endpoints || meta->ripc_endpoint_count == 0U || !meta->ripc_udf_id) {
        rducks_format_error_message(err_msg, err_cap, "RIPC provider is not configured for this UDF");
        return 0;
    }
    n = duckdb_data_chunk_get_size(input);
    rducks_udf_record_evaluator(meta, n);
    if (!rducks_quack_encode_input_chunk_native(runtime, meta, input, &input_payload, err_msg, err_cap)) goto cleanup;
    request_payload = input_payload.data;
    request_payload_size = input_payload.size;
    if (meta->dynamic_args) {
        /* Omitted-args UDFs resolve concrete types per call site at bind; carry
         * those resolved types to the worker in the RDT1 dynamic payload. */
        if (!rducks_ripc_build_dynamic_payload(meta, input_payload.data, input_payload.size,
                                               &dynamic_payload, err_msg, err_cap)) goto cleanup;
        request_payload = dynamic_payload.data;
        request_payload_size = dynamic_payload.size;
    }
    if (!rducks_ripc_build_execute_request(meta, n, request_payload, request_payload_size,
                                           meta->dynamic_args ? 1 : 0, &request, err_msg, err_cap)) goto cleanup;

    rducks_udf_record_ripc_inflight_add(meta);
    client_pool = rducks_ripc_acquire_pool(meta, err_msg, err_cap);
    if (!client_pool) {
        rducks_udf_record_ripc_inflight_done(meta, 1U);
        goto cleanup;
    }
    if (!rducks_nng_client_pool_request_reply_borrowed_acquired(client_pool, request.data, request.size,
                                                               &response_msg, &response, &response_size,
                                                               err_msg, err_cap)) {
        rducks_nng_client_pool_release(client_pool);
        rducks_udf_record_ripc_inflight_done(meta, 1U);
        goto cleanup;
    }
    rducks_nng_client_pool_release(client_pool);
    rducks_udf_record_ripc_inflight_done(meta, 1U);
    rducks_udf_record_ripc_submit_wave(meta, 1U);
    rducks_udf_record_ripc_collect_ready(meta, 1U);
    rducks_udf_record_ripc_batch(meta, 1U);
    if (!rducks_ripc_parse_response(response, response_size, &result_payload, &result_payload_size, err_msg, err_cap)) goto cleanup;
    if (!rducks_quack_decode_result_to_vector(runtime, result_payload, result_payload_size,
                                             meta->return_desc, n, output, err_msg, err_cap)) goto cleanup;
    ok = 1;

cleanup:
    rducks_owned_bytes_reset(&dynamic_payload);
    rducks_owned_bytes_reset(&input_payload);
    rducks_owned_bytes_reset(&request);
    rducks_nng_response_msg_free(response_msg);
    return ok;
}
