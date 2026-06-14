/* Included by ../rducks_extension.c. */

/* Registration-time scalar token parser.  Execution marshalling materializes
 * DuckDB vectors directly to SEXPs, not through this token switch.
 */
static rducks_type_id_t rducks_scalar_type_id_from_token(const char *raw_token) {
    char token[64];
    size_t len;
    if (!raw_token) {
        return RDUCKS_TYPE_INVALID;
    }
    while (*raw_token == ' ' || *raw_token == '\t' || *raw_token == '\n' || *raw_token == '\r') {
        raw_token++;
    }
    len = strlen(raw_token);
    while (len > 0 && (raw_token[len - 1U] == ' ' || raw_token[len - 1U] == '\t' ||
                       raw_token[len - 1U] == '\n' || raw_token[len - 1U] == '\r')) {
        len--;
    }
    if (len == 0 || len >= sizeof(token)) {
        return RDUCKS_TYPE_INVALID;
    }
    memcpy(token, raw_token, len);
    token[len] = '\0';
    rducks_ascii_lower_inplace(token);

    if (strcmp(token, "bool") == 0) return RDUCKS_TYPE_BOOL;
    if (strcmp(token, "i8") == 0) return RDUCKS_TYPE_I8;
    if (strcmp(token, "u8") == 0) return RDUCKS_TYPE_U8;
    if (strcmp(token, "i16") == 0) return RDUCKS_TYPE_I16;
    if (strcmp(token, "u16") == 0) return RDUCKS_TYPE_U16;
    if (strcmp(token, "i32") == 0) return RDUCKS_TYPE_I32;
    if (strcmp(token, "u32") == 0) return RDUCKS_TYPE_U32;
    if (strcmp(token, "i64") == 0) return RDUCKS_TYPE_I64;
    if (strcmp(token, "u64") == 0) return RDUCKS_TYPE_U64;
    if (strcmp(token, "f32") == 0) return RDUCKS_TYPE_F32;
    if (strcmp(token, "f64") == 0) return RDUCKS_TYPE_F64;
    if (strcmp(token, "varchar") == 0) return RDUCKS_TYPE_VARCHAR;
    if (strcmp(token, "blob") == 0) return RDUCKS_TYPE_BLOB;
    if (strcmp(token, "geometry") == 0) return RDUCKS_TYPE_GEOMETRY;
    if (strcmp(token, "variant") == 0) return RDUCKS_TYPE_VARIANT;
    if (strcmp(token, "date") == 0) return RDUCKS_TYPE_DATE;
    if (strcmp(token, "time") == 0) return RDUCKS_TYPE_TIME;
    if (strcmp(token, "timestamp") == 0) return RDUCKS_TYPE_TIMESTAMP;
    if (strcmp(token, "hugeint") == 0) return RDUCKS_TYPE_HUGEINT;
    if (strcmp(token, "uhugeint") == 0) return RDUCKS_TYPE_UHUGEINT;
    if (strcmp(token, "uuid") == 0) return RDUCKS_TYPE_UUID;
    if (strcmp(token, "interval") == 0) return RDUCKS_TYPE_INTERVAL;
    if (strcmp(token, "bit") == 0) return RDUCKS_TYPE_BIT;
    return RDUCKS_TYPE_INVALID;
}

static duckdb_type rducks_duckdb_type_id(rducks_type_id_t type) {
    switch (type) {
    case RDUCKS_TYPE_BOOL:
        return DUCKDB_TYPE_BOOLEAN;
    case RDUCKS_TYPE_I8:
        return DUCKDB_TYPE_TINYINT;
    case RDUCKS_TYPE_U8:
        return DUCKDB_TYPE_UTINYINT;
    case RDUCKS_TYPE_I16:
        return DUCKDB_TYPE_SMALLINT;
    case RDUCKS_TYPE_U16:
        return DUCKDB_TYPE_USMALLINT;
    case RDUCKS_TYPE_I32:
        return DUCKDB_TYPE_INTEGER;
    case RDUCKS_TYPE_U32:
        return DUCKDB_TYPE_UINTEGER;
    case RDUCKS_TYPE_I64:
        return DUCKDB_TYPE_BIGINT;
    case RDUCKS_TYPE_U64:
        return DUCKDB_TYPE_UBIGINT;
    case RDUCKS_TYPE_F32:
        return DUCKDB_TYPE_FLOAT;
    case RDUCKS_TYPE_F64:
        return DUCKDB_TYPE_DOUBLE;
    case RDUCKS_TYPE_VARCHAR:
        return DUCKDB_TYPE_VARCHAR;
    case RDUCKS_TYPE_BLOB:
        return DUCKDB_TYPE_BLOB;
    case RDUCKS_TYPE_GEOMETRY:
        return DUCKDB_TYPE_GEOMETRY;
    case RDUCKS_TYPE_VARIANT:
        return RDUCKS_DUCKDB_TYPE_VARIANT;
    case RDUCKS_TYPE_DATE:
        return DUCKDB_TYPE_DATE;
    case RDUCKS_TYPE_TIME:
        return DUCKDB_TYPE_TIME;
    case RDUCKS_TYPE_TIMESTAMP:
        return DUCKDB_TYPE_TIMESTAMP;
    case RDUCKS_TYPE_HUGEINT:
        return DUCKDB_TYPE_HUGEINT;
    case RDUCKS_TYPE_UHUGEINT:
        return DUCKDB_TYPE_UHUGEINT;
    case RDUCKS_TYPE_UUID:
        return DUCKDB_TYPE_UUID;
    case RDUCKS_TYPE_INTERVAL:
        return DUCKDB_TYPE_INTERVAL;
    case RDUCKS_TYPE_BIT:
        return DUCKDB_TYPE_BIT;
    default:
        return DUCKDB_TYPE_INVALID;
    }
}

static duckdb_logical_type rducks_create_logical_type_for_id(rducks_type_id_t type) {
    duckdb_type duckdb_type_id = rducks_duckdb_type_id(type);
    duckdb_logical_type out;
    if (duckdb_type_id == DUCKDB_TYPE_INVALID) {
        return NULL;
    }
    out = duckdb_create_logical_type(duckdb_type_id);
    if (!out) return NULL;
    if (duckdb_get_type_id(out) != duckdb_type_id) {
        duckdb_destroy_logical_type(&out);
        return NULL;
    }
    return out;
}

static char *rducks_strdup_trimmed_len(const char *x, size_t len) {
    while (len > 0 && (*x == ' ' || *x == '\t' || *x == '\n' || *x == '\r')) {
        x++;
        len--;
    }
    while (len > 0 && (x[len - 1U] == ' ' || x[len - 1U] == '\t' || x[len - 1U] == '\n' || x[len - 1U] == '\r')) {
        len--;
    }
    return rducks_strdup_len(x, len);
}

static int rducks_hex_value(char ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}

static char *rducks_strdup_token_name_len(const char *x, size_t len) {
    char *out;
    size_t out_len = 0;
    while (len > 0 && (*x == ' ' || *x == '\t' || *x == '\n' || *x == '\r')) {
        x++;
        len--;
    }
    while (len > 0 && (x[len - 1U] == ' ' || x[len - 1U] == '\t' || x[len - 1U] == '\n' || x[len - 1U] == '\r')) {
        len--;
    }
    out = (char *)malloc(len + 1U);
    if (!out) return NULL;
    for (size_t i = 0; i < len; i++) {
        if (x[i] == '%') {
            int hi;
            int lo;
            if (i + 2U >= len) {
                free(out);
                return NULL;
            }
            hi = rducks_hex_value(x[i + 1U]);
            lo = rducks_hex_value(x[i + 2U]);
            if (hi < 0 || lo < 0) {
                free(out);
                return NULL;
            }
            out[out_len++] = (char)((hi << 4) | lo);
            i += 2U;
        } else {
            out[out_len++] = x[i];
        }
    }
    out[out_len] = '\0';
    return out;
}

static int rducks_is_wrapped_by_angle(const char *x, const char *prefix, const char **inner, size_t *inner_len) {
    size_t prefix_len = strlen(prefix);
    size_t len;
    int depth = 0;
    if (strncmp(x, prefix, prefix_len) != 0 || x[prefix_len] != '<') return 0;
    len = strlen(x);
    if (len <= prefix_len + 2U || x[len - 1U] != '>') return 0;
    for (size_t i = prefix_len + 1U; i < len - 1U; i++) {
        if (x[i] == '<') depth++;
        else if (x[i] == '>') {
            if (depth == 0) return 0;
            depth--;
        }
    }
    if (depth != 0) return 0;
    *inner = x + prefix_len + 1U;
    *inner_len = len - prefix_len - 2U;
    return 1;
}

static const char *rducks_find_top_level_char_len(const char *x, size_t len, char target) {
    int angle = 0;
    int square = 0;
    for (size_t i = 0; i < len; i++) {
        if (x[i] == '<') angle++;
        else if (x[i] == '>') { if (angle > 0) angle--; }
        else if (x[i] == '[') square++;
        else if (x[i] == ']') { if (square > 0) square--; }
        else if (x[i] == target && angle == 0 && square == 0) return x + i;
    }
    return NULL;
}

static const char *rducks_find_array_suffix(const char *x) {
    size_t len = strlen(x);
    int angle = 0;
    if (len < 2 || x[len - 1U] != ']') return NULL;
    for (size_t i = len; i > 0; --i) {
        char ch = x[i - 1U];
        if (ch == '>') angle++;
        else if (ch == '<') { if (angle > 0) angle--; }
        else if (ch == '[' && angle == 0) return x + i - 1U;
    }
    return NULL;
}

static void rducks_type_desc_destroy(rducks_type_desc_t *desc) {
    if (!desc) return;
    rducks_type_desc_destroy(desc->child);
    rducks_type_desc_destroy(desc->key);
    rducks_type_desc_destroy(desc->value);
    if (desc->field_names) {
        for (size_t i = 0; i < desc->field_count; i++) free(desc->field_names[i]);
        free(desc->field_names);
    }
    if (desc->field_types) {
        for (size_t i = 0; i < desc->field_count; i++) rducks_type_desc_destroy(desc->field_types[i]);
        free(desc->field_types);
    }
    free(desc->field_hash_heads);
    free(desc->field_hash_next);
    free(desc);
}

static int rducks_type_desc_contains_scalar(const rducks_type_desc_t *desc, rducks_type_id_t scalar) {
    if (!desc) return 0;
    if (desc->kind == RDUCKS_KIND_SCALAR) return desc->scalar == scalar;
    if (rducks_type_desc_contains_scalar(desc->child, scalar) ||
        rducks_type_desc_contains_scalar(desc->key, scalar) ||
        rducks_type_desc_contains_scalar(desc->value, scalar)) {
        return 1;
    }
    if (desc->field_types) {
        for (size_t i = 0; i < desc->field_count; i++) {
            if (rducks_type_desc_contains_scalar(desc->field_types[i], scalar)) return 1;
        }
    }
    return 0;
}

static rducks_type_desc_t *rducks_type_desc_new(rducks_type_kind_t kind) {
    rducks_type_desc_t *desc = (rducks_type_desc_t *)rducks_calloc_array(1, sizeof(*desc));
    if (desc) desc->kind = kind;
    return desc;
}

static uint64_t rducks_type_desc_field_hash(const char *text) {
    const unsigned char *p = (const unsigned char *)(text ? text : "");
    uint64_t h = 1469598103934665603ULL;
    while (*p) {
        h ^= (uint64_t)*p++;
        h *= 1099511628211ULL;
    }
    return h;
}

static size_t rducks_type_desc_hash_bucket_count(size_t count) {
    size_t buckets = 8U;
    if (count > (SIZE_MAX / 2U)) return 0U;
    while (buckets < count * 2U) {
        if (buckets > (SIZE_MAX / 2U)) return 0U;
        buckets *= 2U;
    }
    return buckets;
}

static int rducks_type_desc_build_field_hash(rducks_type_desc_t *desc) {
    size_t buckets;
    uint32_t *heads;
    uint32_t *next;
    if (!desc || !desc->field_count || !desc->field_names) return 1;
    if (desc->field_hash_heads && desc->field_hash_next && desc->field_hash_bucket_count) return 1;
    if (desc->field_count > (size_t)UINT32_MAX) return 0;
    buckets = rducks_type_desc_hash_bucket_count(desc->field_count);
    if (!buckets) return 0;
    heads = (uint32_t *)rducks_calloc_array(buckets, sizeof(*heads));
    next = (uint32_t *)rducks_calloc_array(desc->field_count, sizeof(*next));
    if (!heads || !next) {
        free(heads);
        free(next);
        return 0;
    }
    for (size_t i = 0; i < buckets; i++) heads[i] = UINT32_MAX;
    for (size_t i = 0; i < desc->field_count; i++) next[i] = UINT32_MAX;
    for (size_t i = 0; i < desc->field_count; i++) {
        size_t bucket = (size_t)(rducks_type_desc_field_hash(desc->field_names[i]) & (uint64_t)(buckets - 1U));
        next[i] = heads[bucket];
        heads[bucket] = (uint32_t)i;
    }
    desc->field_hash_heads = heads;
    desc->field_hash_next = next;
    desc->field_hash_bucket_count = buckets;
    return 1;
}

static int rducks_type_desc_find_field_index(const rducks_type_desc_t *desc, const char *name,
                                             size_t *index_out) {
    if (index_out) *index_out = 0U;
    if (!desc || !name || !desc->field_names) return 0;
    if (desc->field_hash_heads && desc->field_hash_next && desc->field_hash_bucket_count) {
        size_t bucket = (size_t)(rducks_type_desc_field_hash(name) &
                                 (uint64_t)(desc->field_hash_bucket_count - 1U));
        for (uint32_t i = desc->field_hash_heads[bucket]; i != UINT32_MAX; i = desc->field_hash_next[i]) {
            if ((size_t)i < desc->field_count && desc->field_names[i] && strcmp(name, desc->field_names[i]) == 0) {
                if (index_out) *index_out = (size_t)i;
                return 1;
            }
        }
        return 0;
    }
    for (size_t i = 0; i < desc->field_count; i++) {
        if (desc->field_names[i] && strcmp(name, desc->field_names[i]) == 0) {
            if (index_out) *index_out = i;
            return 1;
        }
    }
    return 0;
}

static void rducks_type_desc_array_destroy(rducks_type_desc_t **items, size_t count) {
    if (!items) return;
    for (size_t i = 0; i < count; i++) rducks_type_desc_destroy(items[i]);
    free(items);
}

static rducks_type_desc_t *rducks_type_desc_clone(const rducks_type_desc_t *src) {
    rducks_type_desc_t *dst;
    if (!src) return NULL;
    dst = rducks_type_desc_new(src->kind);
    if (!dst) return NULL;
    dst->scalar = src->scalar;
    dst->array_size = src->array_size;
    dst->decimal_width = src->decimal_width;
    dst->decimal_scale = src->decimal_scale;
    dst->enum_internal_type = src->enum_internal_type;
    dst->field_count = src->field_count;
    if (src->child) {
        dst->child = rducks_type_desc_clone(src->child);
        if (!dst->child) goto fail;
    }
    if (src->key) {
        dst->key = rducks_type_desc_clone(src->key);
        if (!dst->key) goto fail;
    }
    if (src->value) {
        dst->value = rducks_type_desc_clone(src->value);
        if (!dst->value) goto fail;
    }
    if (src->field_count) {
        dst->field_names = (char **)rducks_calloc_array(src->field_count, sizeof(*dst->field_names));
        if (!dst->field_names) goto fail;
        if (src->field_types) {
            dst->field_types = (rducks_type_desc_t **)rducks_calloc_array(src->field_count, sizeof(*dst->field_types));
            if (!dst->field_types) goto fail;
        }
        for (size_t i = 0; i < src->field_count; i++) {
            dst->field_names[i] = rducks_strdup(src->field_names[i] ? src->field_names[i] : "");
            if (!dst->field_names[i]) goto fail;
            if (src->field_types) {
                dst->field_types[i] = rducks_type_desc_clone(src->field_types[i]);
                if (!dst->field_types[i]) goto fail;
            }
        }
        if (!rducks_type_desc_build_field_hash(dst)) goto fail;
    }
    return dst;
fail:
    rducks_type_desc_destroy(dst);
    return NULL;
}

static rducks_type_desc_t **rducks_type_desc_array_clone(rducks_type_desc_t **src, size_t count) {
    rducks_type_desc_t **dst;
    if (!count) return NULL;
    if (!src || count > SIZE_MAX / sizeof(*dst)) return NULL;
    dst = (rducks_type_desc_t **)rducks_calloc_array(count, sizeof(*dst));
    if (!dst) return NULL;
    for (size_t i = 0; i < count; i++) {
        dst[i] = rducks_type_desc_clone(src[i]);
        if (!dst[i]) {
            rducks_type_desc_array_destroy(dst, count);
            return NULL;
        }
    }
    return dst;
}

static int rducks_parse_type_desc_text(const char *text, rducks_type_desc_t **out, char *err, size_t err_cap);

static int rducks_parse_type_desc_len(const char *text, size_t len, rducks_type_desc_t **out, char *err, size_t err_cap) {
    char *copy = rducks_strdup_trimmed_len(text, len);
    int ok;
    if (!copy) {
        rducks_format_error_message(err, err_cap, "out of memory");
        return 0;
    }
    ok = rducks_parse_type_desc_text(copy, out, err, err_cap);
    free(copy);
    return ok;
}

static int rducks_parse_type_desc_text(const char *text, rducks_type_desc_t **out, char *err, size_t err_cap) {
    const char *inner = NULL;
    size_t inner_len = 0;
    const char *suffix;
    rducks_type_desc_t *desc = NULL;
    if (!text || !out) return 0;
    *out = NULL;

    if (rducks_is_wrapped_by_angle(text, "decimal", &inner, &inner_len)) {
        const char *sep = rducks_find_top_level_char_len(inner, inner_len, ';');
        char *width_text = NULL;
        char *scale_text = NULL;
        char *endp = NULL;
        long width;
        long scale;
        if (!sep) sep = rducks_find_top_level_char_len(inner, inner_len, ',');
        if (!sep) {
            rducks_format_error_message(err, err_cap, "decimal type must be decimal<width;scale>");
            return 0;
        }
        width_text = rducks_strdup_trimmed_len(inner, (size_t)(sep - inner));
        scale_text = rducks_strdup_trimmed_len(sep + 1, inner_len - (size_t)(sep - inner) - 1U);
        if (!width_text || !scale_text) {
            free(width_text);
            free(scale_text);
            goto oom;
        }
        width = strtol(width_text, &endp, 10);
        if (!endp || *endp != '\0') {
            free(width_text);
            free(scale_text);
            rducks_format_error_message(err, err_cap, "invalid decimal width");
            return 0;
        }
        scale = strtol(scale_text, &endp, 10);
        if (!endp || *endp != '\0') {
            free(width_text);
            free(scale_text);
            rducks_format_error_message(err, err_cap, "invalid decimal scale");
            return 0;
        }
        free(width_text);
        free(scale_text);
        if (width < 1 || width > 38 || scale < 0 || scale > width) {
            rducks_format_error_message(err, err_cap, "invalid decimal width or scale");
            return 0;
        }
        desc = rducks_type_desc_new(RDUCKS_KIND_DECIMAL);
        if (!desc) goto oom;
        desc->decimal_width = (uint8_t)width;
        desc->decimal_scale = (uint8_t)scale;
        *out = desc;
        return 1;
    }
    if (rducks_is_wrapped_by_angle(text, "enum", &inner, &inner_len)) {
        size_t count = 0, cap = 0;
        const char *cursor = inner;
        size_t remain = inner_len;
        desc = rducks_type_desc_new(RDUCKS_KIND_ENUM);
        if (!desc) goto oom;
        while (remain > 0) {
            const char *sep = memchr(cursor, '|', remain);
            size_t part_len = sep ? (size_t)(sep - cursor) : remain;
            char *level;
            if (count == cap) {
                size_t new_cap = cap == 0 ? 4U : cap * 2U;
                char **new_names;
                if (new_cap <= cap) goto oom;
                new_names = (char **)rducks_realloc_array(desc->field_names, new_cap, sizeof(*new_names));
                if (!new_names) goto oom;
                desc->field_names = new_names;
                for (size_t j = cap; j < new_cap; j++) desc->field_names[j] = NULL;
                cap = new_cap;
            }
            level = rducks_strdup_token_name_len(cursor, part_len);
            if (!level) goto oom;
            if (!level[0]) {
                free(level);
                rducks_format_error_message(err, err_cap, "enum levels must be non-empty");
                goto fail;
            }
            desc->field_names[count++] = level;
            desc->field_count = count;
            if (!sep) break;
            cursor = sep + 1;
            remain = inner_len - (size_t)(cursor - inner);
        }
        if (desc->field_count == 0) {
            rducks_format_error_message(err, err_cap, "enum type must contain at least one level");
            goto fail;
        }
        if (!rducks_type_desc_build_field_hash(desc)) goto oom;
        *out = desc;
        return 1;
    }
    if (rducks_is_wrapped_by_angle(text, "union", &inner, &inner_len)) {
        size_t count = 0, cap = 0;
        const char *cursor = inner;
        size_t remain = inner_len;
        desc = rducks_type_desc_new(RDUCKS_KIND_UNION);
        if (!desc) goto oom;
        while (remain > 0) {
            const char *sep = rducks_find_top_level_char_len(cursor, remain, ';');
            size_t part_len = sep ? (size_t)(sep - cursor) : remain;
            const char *colon = rducks_find_top_level_char_len(cursor, part_len, ':');
            if (!colon) {
                rducks_format_error_message(err, err_cap, "union members must be name:type");
                goto fail;
            }
            if (count == cap) {
                size_t new_cap = cap == 0 ? 4U : cap * 2U;
                char **new_names;
                rducks_type_desc_t **new_types;
                if (new_cap <= cap) goto oom;
                new_names = (char **)rducks_realloc_array(desc->field_names, new_cap, sizeof(*new_names));
                if (!new_names) goto oom;
                desc->field_names = new_names;
                new_types = (rducks_type_desc_t **)rducks_realloc_array(desc->field_types, new_cap, sizeof(*new_types));
                if (!new_types) goto oom;
                desc->field_types = new_types;
                for (size_t j = cap; j < new_cap; j++) {
                    desc->field_names[j] = NULL;
                    desc->field_types[j] = NULL;
                }
                cap = new_cap;
            }
            desc->field_names[count] = rducks_strdup_token_name_len(cursor, (size_t)(colon - cursor));
            if (!desc->field_names[count]) goto oom;
            if (!rducks_parse_type_desc_len(colon + 1, part_len - (size_t)(colon - cursor) - 1U,
                                            &desc->field_types[count], err, err_cap)) goto fail;
            count++;
            desc->field_count = count;
            if (!sep) break;
            cursor = sep + 1;
            remain = inner_len - (size_t)(cursor - inner);
        }
        if (desc->field_count == 0 || desc->field_count > 255U) {
            rducks_format_error_message(err, err_cap, "union type must contain 1 to 255 members");
            goto fail;
        }
        if (!rducks_type_desc_build_field_hash(desc)) goto oom;
        *out = desc;
        return 1;
    }

    if (rducks_is_wrapped_by_angle(text, "list", &inner, &inner_len)) {
        desc = rducks_type_desc_new(RDUCKS_KIND_LIST);
        if (!desc || !rducks_parse_type_desc_len(inner, inner_len, &desc->child, err, err_cap)) goto fail;
        *out = desc;
        return 1;
    }
    if (rducks_is_wrapped_by_angle(text, "map", &inner, &inner_len)) {
        const char *sep = rducks_find_top_level_char_len(inner, inner_len, ';');
        if (!sep) sep = rducks_find_top_level_char_len(inner, inner_len, ',');
        if (!sep) {
            rducks_format_error_message(err, err_cap, "map type must be map<key;value>");
            return 0;
        }
        desc = rducks_type_desc_new(RDUCKS_KIND_MAP);
        if (!desc || !rducks_parse_type_desc_len(inner, (size_t)(sep - inner), &desc->key, err, err_cap) ||
            !rducks_parse_type_desc_len(sep + 1, inner_len - (size_t)(sep - inner) - 1U, &desc->value, err, err_cap)) goto fail;
        *out = desc;
        return 1;
    }
    if (rducks_is_wrapped_by_angle(text, "struct", &inner, &inner_len)) {
        size_t count = 0, cap = 0;
        const char *cursor = inner;
        size_t remain = inner_len;
        desc = rducks_type_desc_new(RDUCKS_KIND_STRUCT);
        if (!desc) goto oom;
        while (remain > 0) {
            const char *sep = rducks_find_top_level_char_len(cursor, remain, ';');
            size_t part_len = sep ? (size_t)(sep - cursor) : remain;
            const char *colon = rducks_find_top_level_char_len(cursor, part_len, ':');
            if (!colon) {
                rducks_format_error_message(err, err_cap, "struct fields must be name:type");
                goto fail;
            }
            if (count == cap) {
                size_t new_cap = cap == 0 ? 4U : cap * 2U;
                char **new_names;
                rducks_type_desc_t **new_types;
                if (new_cap <= cap) goto oom;
                new_names = (char **)rducks_realloc_array(desc->field_names, new_cap, sizeof(*new_names));
                if (!new_names) goto oom;
                desc->field_names = new_names;
                new_types = (rducks_type_desc_t **)rducks_realloc_array(desc->field_types, new_cap, sizeof(*new_types));
                if (!new_types) goto oom;
                desc->field_types = new_types;
                for (size_t j = cap; j < new_cap; j++) {
                    desc->field_names[j] = NULL;
                    desc->field_types[j] = NULL;
                }
                cap = new_cap;
            }
            desc->field_names[count] = rducks_strdup_token_name_len(cursor, (size_t)(colon - cursor));
            if (!desc->field_names[count]) goto oom;
            if (!rducks_parse_type_desc_len(colon + 1, part_len - (size_t)(colon - cursor) - 1U, &desc->field_types[count], err, err_cap)) goto fail;
            count++;
            desc->field_count = count;
            if (!sep) break;
            cursor = sep + 1;
            remain = inner_len - (size_t)(cursor - inner);
        }
        if (desc->field_count == 0) {
            rducks_format_error_message(err, err_cap, "struct type must contain at least one field");
            goto fail;
        }
        *out = desc;
        return 1;
    }
    suffix = rducks_find_array_suffix(text);
    if (suffix) {
        size_t prefix_len = (size_t)(suffix - text);
        size_t len = strlen(text);
        size_t bracket_len = len - prefix_len - 2U;
        desc = rducks_type_desc_new(bracket_len == 0 ? RDUCKS_KIND_LIST : RDUCKS_KIND_ARRAY);
        if (!desc || !rducks_parse_type_desc_len(text, prefix_len, &desc->child, err, err_cap)) goto fail;
        if (bracket_len > 0) {
            char *ntext = rducks_strdup_len(suffix + 1, bracket_len);
            char *endp = NULL;
            unsigned long long nval;
            if (!ntext) goto oom;
            nval = strtoull(ntext, &endp, 10);
            if (!endp || *endp != '\0' || nval == 0 || nval > (unsigned long long)UINT64_MAX) {
                free(ntext);
                rducks_format_error_message(err, err_cap, "invalid array size");
                goto fail;
            }
            desc->array_size = (idx_t)nval;
            free(ntext);
        }
        *out = desc;
        return 1;
    }
    {
        rducks_type_id_t scalar = rducks_scalar_type_id_from_token(text);
        if (scalar == RDUCKS_TYPE_INVALID) {
            rducks_format_error_message(err, err_cap, "unsupported Rducks type: %s", text);
            return 0;
        }
        desc = rducks_type_desc_new(RDUCKS_KIND_SCALAR);
        if (!desc) goto oom;
        desc->scalar = scalar;
        *out = desc;
        return 1;
    }

oom:
    rducks_format_error_message(err, err_cap, "out of memory");
fail:
    rducks_type_desc_destroy(desc);
    return 0;
}

static duckdb_logical_type rducks_create_logical_type_for_desc(rducks_type_desc_t *desc) {
    if (!desc) return NULL;
    if (desc->kind == RDUCKS_KIND_SCALAR) return rducks_create_logical_type_for_id(desc->scalar);
    if (desc->kind == RDUCKS_KIND_LIST) {
        duckdb_logical_type child = rducks_create_logical_type_for_desc(desc->child);
        duckdb_logical_type out;
        if (!child) return NULL;
        out = duckdb_create_list_type(child);
        duckdb_destroy_logical_type(&child);
        return out;
    }
    if (desc->kind == RDUCKS_KIND_ARRAY) {
        duckdb_logical_type child = rducks_create_logical_type_for_desc(desc->child);
        duckdb_logical_type out;
        if (!child || desc->array_size == 0) {
            if (child) duckdb_destroy_logical_type(&child);
            return NULL;
        }
        out = duckdb_create_array_type(child, desc->array_size);
        duckdb_destroy_logical_type(&child);
        return out;
    }
    if (desc->kind == RDUCKS_KIND_MAP) {
        duckdb_logical_type key = rducks_create_logical_type_for_desc(desc->key);
        duckdb_logical_type value = rducks_create_logical_type_for_desc(desc->value);
        duckdb_logical_type out = NULL;
        if (key && value) out = duckdb_create_map_type(key, value);
        if (key) duckdb_destroy_logical_type(&key);
        if (value) duckdb_destroy_logical_type(&value);
        return out;
    }
    if (desc->kind == RDUCKS_KIND_STRUCT) {
        duckdb_logical_type *types;
        duckdb_logical_type out = NULL;
        if (desc->field_count == 0 || desc->field_count > (SIZE_MAX / sizeof(*types))) return NULL;
        types = (duckdb_logical_type *)rducks_calloc_array(desc->field_count, sizeof(*types));
        if (!types) return NULL;
        for (size_t i = 0; i < desc->field_count; i++) {
            types[i] = rducks_create_logical_type_for_desc(desc->field_types[i]);
            if (!types[i]) goto cleanup_struct;
        }
        out = duckdb_create_struct_type(types, (const char **)desc->field_names, (idx_t)desc->field_count);
cleanup_struct:
        for (size_t i = 0; i < desc->field_count; i++) if (types[i]) duckdb_destroy_logical_type(&types[i]);
        free(types);
        return out;
    }
    if (desc->kind == RDUCKS_KIND_DECIMAL) {
        return duckdb_create_decimal_type(desc->decimal_width, desc->decimal_scale);
    }
    if (desc->kind == RDUCKS_KIND_ENUM) {
        duckdb_logical_type out;
        if (desc->field_count == 0) return NULL;
        out = duckdb_create_enum_type((const char **)desc->field_names, (idx_t)desc->field_count);
        if (out) {
            desc->enum_internal_type = duckdb_enum_internal_type(out);
        }
        return out;
    }
    if (desc->kind == RDUCKS_KIND_UNION) {
        duckdb_logical_type *types;
        duckdb_logical_type out = NULL;
        if (desc->field_count == 0 || desc->field_count > 255U || desc->field_count > (SIZE_MAX / sizeof(*types))) return NULL;
        types = (duckdb_logical_type *)rducks_calloc_array(desc->field_count, sizeof(*types));
        if (!types) return NULL;
        for (size_t i = 0; i < desc->field_count; i++) {
            types[i] = rducks_create_logical_type_for_desc(desc->field_types[i]);
            if (!types[i]) goto cleanup_union;
        }
        out = duckdb_create_union_type(types, (const char **)desc->field_names, (idx_t)desc->field_count);
cleanup_union:
        for (size_t i = 0; i < desc->field_count; i++) if (types[i]) duckdb_destroy_logical_type(&types[i]);
        free(types);
        return out;
    }
    return NULL;
}

typedef struct rducks_strbuf {
    char *data;
    size_t len;
    size_t cap;
} rducks_strbuf_t;

static int rducks_strbuf_reserve(rducks_strbuf_t *buf, size_t extra) {
    size_t need;
    size_t new_cap;
    char *new_data;
    if (!buf || extra > SIZE_MAX - buf->len - 1U) return 0;
    need = buf->len + extra + 1U;
    if (need <= buf->cap) return 1;
    new_cap = buf->cap ? buf->cap : 64U;
    while (new_cap < need) {
        if (new_cap > SIZE_MAX / 2U) return 0;
        new_cap *= 2U;
    }
    new_data = (char *)realloc(buf->data, new_cap);
    if (!new_data) return 0;
    buf->data = new_data;
    buf->cap = new_cap;
    return 1;
}

static int rducks_strbuf_append_len(rducks_strbuf_t *buf, const char *text, size_t n) {
    if (!rducks_strbuf_reserve(buf, n)) return 0;
    if (n) memcpy(buf->data + buf->len, text, n);
    buf->len += n;
    buf->data[buf->len] = '\0';
    return 1;
}

static int rducks_strbuf_append(rducks_strbuf_t *buf, const char *text) {
    return rducks_strbuf_append_len(buf, text ? text : "", text ? strlen(text) : 0U);
}

static int rducks_strbuf_append_char(rducks_strbuf_t *buf, char ch) {
    return rducks_strbuf_append_len(buf, &ch, 1U);
}

static int rducks_token_name_safe(unsigned char ch) {
    return (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
           (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' || ch == '.';
}

static int rducks_strbuf_append_token_name(rducks_strbuf_t *buf, const char *text) {
    static const char hex[] = "0123456789ABCDEF";
    const unsigned char *p = (const unsigned char *)(text ? text : "");
    while (*p) {
        if (rducks_token_name_safe(*p)) {
            if (!rducks_strbuf_append_char(buf, (char)*p)) return 0;
        } else {
            char encoded[3];
            encoded[0] = '%';
            encoded[1] = hex[(*p >> 4) & 0x0fU];
            encoded[2] = hex[*p & 0x0fU];
            if (!rducks_strbuf_append_len(buf, encoded, sizeof(encoded))) return 0;
        }
        p++;
    }
    return 1;
}

static const char *rducks_type_id_token(rducks_type_id_t scalar) {
    switch (scalar) {
    case RDUCKS_TYPE_BOOL: return "bool";
    case RDUCKS_TYPE_I8: return "i8";
    case RDUCKS_TYPE_U8: return "u8";
    case RDUCKS_TYPE_I16: return "i16";
    case RDUCKS_TYPE_U16: return "u16";
    case RDUCKS_TYPE_I32: return "i32";
    case RDUCKS_TYPE_U32: return "u32";
    case RDUCKS_TYPE_I64: return "i64";
    case RDUCKS_TYPE_U64: return "u64";
    case RDUCKS_TYPE_F32: return "f32";
    case RDUCKS_TYPE_F64: return "f64";
    case RDUCKS_TYPE_VARCHAR: return "varchar";
    case RDUCKS_TYPE_BLOB: return "blob";
    case RDUCKS_TYPE_GEOMETRY: return "geometry";
    case RDUCKS_TYPE_VARIANT: return "variant";
    case RDUCKS_TYPE_DATE: return "date";
    case RDUCKS_TYPE_TIME: return "time";
    case RDUCKS_TYPE_TIMESTAMP: return "timestamp";
    case RDUCKS_TYPE_HUGEINT: return "hugeint";
    case RDUCKS_TYPE_UHUGEINT: return "uhugeint";
    case RDUCKS_TYPE_UUID: return "uuid";
    case RDUCKS_TYPE_INTERVAL: return "interval";
    case RDUCKS_TYPE_BIT: return "bit";
    default: return NULL;
    }
}

static int rducks_type_desc_append_token(rducks_strbuf_t *buf, const rducks_type_desc_t *desc) {
    char tmp[64];
    if (!buf || !desc) return 0;
    if (desc->kind == RDUCKS_KIND_SCALAR) {
        const char *token = rducks_type_id_token(desc->scalar);
        return token && rducks_strbuf_append(buf, token);
    }
    if (desc->kind == RDUCKS_KIND_DECIMAL) {
        snprintf(tmp, sizeof(tmp), "decimal<%u;%u>", (unsigned)desc->decimal_width, (unsigned)desc->decimal_scale);
        return rducks_strbuf_append(buf, tmp);
    }
    if (desc->kind == RDUCKS_KIND_ENUM) {
        if (!rducks_strbuf_append(buf, "enum<")) return 0;
        for (size_t i = 0; i < desc->field_count; i++) {
            if (i && !rducks_strbuf_append_char(buf, '|')) return 0;
            if (!rducks_strbuf_append_token_name(buf, desc->field_names[i])) return 0;
        }
        return rducks_strbuf_append_char(buf, '>');
    }
    if (desc->kind == RDUCKS_KIND_LIST) {
        return rducks_strbuf_append(buf, "list<") &&
               rducks_type_desc_append_token(buf, desc->child) &&
               rducks_strbuf_append_char(buf, '>');
    }
    if (desc->kind == RDUCKS_KIND_ARRAY) {
        if (!rducks_type_desc_append_token(buf, desc->child)) return 0;
        snprintf(tmp, sizeof(tmp), "[%llu]", (unsigned long long)desc->array_size);
        return rducks_strbuf_append(buf, tmp);
    }
    if (desc->kind == RDUCKS_KIND_MAP) {
        return rducks_strbuf_append(buf, "map<") &&
               rducks_type_desc_append_token(buf, desc->key) &&
               rducks_strbuf_append_char(buf, ';') &&
               rducks_type_desc_append_token(buf, desc->value) &&
               rducks_strbuf_append_char(buf, '>');
    }
    if (desc->kind == RDUCKS_KIND_STRUCT || desc->kind == RDUCKS_KIND_UNION) {
        if (!rducks_strbuf_append(buf, desc->kind == RDUCKS_KIND_STRUCT ? "struct<" : "union<")) return 0;
        for (size_t i = 0; i < desc->field_count; i++) {
            if (i && !rducks_strbuf_append_char(buf, ';')) return 0;
            if (!rducks_strbuf_append_token_name(buf, desc->field_names[i]) ||
                !rducks_strbuf_append_char(buf, ':') ||
                !rducks_type_desc_append_token(buf, desc->field_types[i])) return 0;
        }
        return rducks_strbuf_append_char(buf, '>');
    }
    return 0;
}

static char *rducks_type_desc_token(const rducks_type_desc_t *desc) {
    rducks_strbuf_t buf;
    memset(&buf, 0, sizeof(buf));
    if (!rducks_type_desc_append_token(&buf, desc)) {
        free(buf.data);
        return NULL;
    }
    return buf.data;
}

static rducks_type_id_t rducks_type_id_from_duckdb_type(duckdb_type type_id) {
    if ((int)type_id == RDUCKS_DUCKDB_TYPE_VARIANT_ID) return RDUCKS_TYPE_VARIANT;
    switch (type_id) {
    case DUCKDB_TYPE_BOOLEAN: return RDUCKS_TYPE_BOOL;
    case DUCKDB_TYPE_TINYINT: return RDUCKS_TYPE_I8;
    case DUCKDB_TYPE_UTINYINT: return RDUCKS_TYPE_U8;
    case DUCKDB_TYPE_SMALLINT: return RDUCKS_TYPE_I16;
    case DUCKDB_TYPE_USMALLINT: return RDUCKS_TYPE_U16;
    case DUCKDB_TYPE_INTEGER: return RDUCKS_TYPE_I32;
    case DUCKDB_TYPE_UINTEGER: return RDUCKS_TYPE_U32;
    case DUCKDB_TYPE_BIGINT: return RDUCKS_TYPE_I64;
    case DUCKDB_TYPE_UBIGINT: return RDUCKS_TYPE_U64;
    case DUCKDB_TYPE_FLOAT: return RDUCKS_TYPE_F32;
    case DUCKDB_TYPE_DOUBLE: return RDUCKS_TYPE_F64;
    case DUCKDB_TYPE_VARCHAR: return RDUCKS_TYPE_VARCHAR;
    case DUCKDB_TYPE_BLOB: return RDUCKS_TYPE_BLOB;
    case DUCKDB_TYPE_GEOMETRY: return RDUCKS_TYPE_GEOMETRY;
    case DUCKDB_TYPE_DATE: return RDUCKS_TYPE_DATE;
    case DUCKDB_TYPE_TIME: return RDUCKS_TYPE_TIME;
    case DUCKDB_TYPE_TIMESTAMP: return RDUCKS_TYPE_TIMESTAMP;
    case DUCKDB_TYPE_HUGEINT: return RDUCKS_TYPE_HUGEINT;
    case DUCKDB_TYPE_UHUGEINT: return RDUCKS_TYPE_UHUGEINT;
    case DUCKDB_TYPE_UUID: return RDUCKS_TYPE_UUID;
    case DUCKDB_TYPE_INTERVAL: return RDUCKS_TYPE_INTERVAL;
    case DUCKDB_TYPE_BIT: return RDUCKS_TYPE_BIT;
    default: return RDUCKS_TYPE_INVALID;
    }
}

static int rducks_type_desc_from_logical_type(duckdb_logical_type logical_type,
                                              rducks_type_desc_t **out,
                                              char *err, size_t err_cap) {
    duckdb_type type_id;
    rducks_type_desc_t *desc = NULL;
    if (!logical_type || !out) {
        rducks_format_error_message(err, err_cap, "invalid DuckDB logical type for dynamic Rducks argument");
        return 0;
    }
    *out = NULL;
    type_id = duckdb_get_type_id(logical_type);
    if (type_id == DUCKDB_TYPE_DECIMAL) {
        desc = rducks_type_desc_new(RDUCKS_KIND_DECIMAL);
        if (!desc) goto oom;
        desc->decimal_width = duckdb_decimal_width(logical_type);
        desc->decimal_scale = duckdb_decimal_scale(logical_type);
        *out = desc;
        return 1;
    }
    if (type_id == DUCKDB_TYPE_ENUM) {
        uint32_t n = duckdb_enum_dictionary_size(logical_type);
        desc = rducks_type_desc_new(RDUCKS_KIND_ENUM);
        if (!desc) goto oom;
        desc->enum_internal_type = duckdb_enum_internal_type(logical_type);
        desc->field_count = (size_t)n;
        if (n > 0) {
            desc->field_names = (char **)rducks_calloc_array((size_t)n, sizeof(*desc->field_names));
            if (!desc->field_names) goto oom;
            for (uint32_t i = 0; i < n; i++) {
                char *value = duckdb_enum_dictionary_value(logical_type, (idx_t)i);
                if (!value) goto oom;
                desc->field_names[i] = rducks_strdup(value);
                duckdb_free(value);
                if (!desc->field_names[i]) goto oom;
            }
            if (!rducks_type_desc_build_field_hash(desc)) goto oom;
        }
        *out = desc;
        return 1;
    }
    if (type_id == DUCKDB_TYPE_LIST) {
        duckdb_logical_type child = duckdb_list_type_child_type(logical_type);
        desc = rducks_type_desc_new(RDUCKS_KIND_LIST);
        if (!desc || !child) goto oom;
        if (!rducks_type_desc_from_logical_type(child, &desc->child, err, err_cap)) {
            duckdb_destroy_logical_type(&child);
            goto fail;
        }
        duckdb_destroy_logical_type(&child);
        *out = desc;
        return 1;
    }
    if (type_id == DUCKDB_TYPE_ARRAY) {
        duckdb_logical_type child = duckdb_array_type_child_type(logical_type);
        desc = rducks_type_desc_new(RDUCKS_KIND_ARRAY);
        if (!desc || !child) goto oom;
        desc->array_size = duckdb_array_type_array_size(logical_type);
        if (!rducks_type_desc_from_logical_type(child, &desc->child, err, err_cap)) {
            duckdb_destroy_logical_type(&child);
            goto fail;
        }
        duckdb_destroy_logical_type(&child);
        *out = desc;
        return 1;
    }
    if (type_id == DUCKDB_TYPE_MAP) {
        duckdb_logical_type key = duckdb_map_type_key_type(logical_type);
        duckdb_logical_type value = duckdb_map_type_value_type(logical_type);
        desc = rducks_type_desc_new(RDUCKS_KIND_MAP);
        if (!desc || !key || !value) goto oom;
        if (!rducks_type_desc_from_logical_type(key, &desc->key, err, err_cap) ||
            !rducks_type_desc_from_logical_type(value, &desc->value, err, err_cap)) {
            duckdb_destroy_logical_type(&key);
            duckdb_destroy_logical_type(&value);
            goto fail;
        }
        duckdb_destroy_logical_type(&key);
        duckdb_destroy_logical_type(&value);
        *out = desc;
        return 1;
    }
    if (type_id == DUCKDB_TYPE_STRUCT || type_id == DUCKDB_TYPE_UNION) {
        idx_t n = type_id == DUCKDB_TYPE_STRUCT ? duckdb_struct_type_child_count(logical_type) : duckdb_union_type_member_count(logical_type);
        desc = rducks_type_desc_new(type_id == DUCKDB_TYPE_STRUCT ? RDUCKS_KIND_STRUCT : RDUCKS_KIND_UNION);
        if (!desc || n > (idx_t)(SIZE_MAX / sizeof(*desc->field_names)) || n > (idx_t)(SIZE_MAX / sizeof(*desc->field_types))) goto oom;
        desc->field_count = (size_t)n;
        if (n > 0) {
            desc->field_names = (char **)rducks_calloc_array((size_t)n, sizeof(*desc->field_names));
            desc->field_types = (rducks_type_desc_t **)rducks_calloc_array((size_t)n, sizeof(*desc->field_types));
            if (!desc->field_names || !desc->field_types) goto oom;
            for (idx_t i = 0; i < n; i++) {
                char *name = type_id == DUCKDB_TYPE_STRUCT ? duckdb_struct_type_child_name(logical_type, i) : duckdb_union_type_member_name(logical_type, i);
                duckdb_logical_type child = type_id == DUCKDB_TYPE_STRUCT ? duckdb_struct_type_child_type(logical_type, i) : duckdb_union_type_member_type(logical_type, i);
                if (!name || !child) {
                    if (name) duckdb_free(name);
                    if (child) duckdb_destroy_logical_type(&child);
                    goto oom;
                }
                desc->field_names[i] = rducks_strdup(name);
                duckdb_free(name);
                if (!desc->field_names[i]) {
                    duckdb_destroy_logical_type(&child);
                    goto oom;
                }
                if (!rducks_type_desc_from_logical_type(child, &desc->field_types[i], err, err_cap)) {
                    duckdb_destroy_logical_type(&child);
                    goto fail;
                }
                duckdb_destroy_logical_type(&child);
            }
            if (!rducks_type_desc_build_field_hash(desc)) goto oom;
        }
        *out = desc;
        return 1;
    }
    {
        rducks_type_id_t scalar = rducks_type_id_from_duckdb_type(type_id);
        if (scalar == RDUCKS_TYPE_INVALID) {
            if (type_id == DUCKDB_TYPE_INVALID || type_id == DUCKDB_TYPE_SQLNULL || type_id == DUCKDB_TYPE_ANY) {
                snprintf(
                    err,
                    err_cap,
                    "dynamic Rducks arguments must bind to concrete DuckDB types; cast NULL/parameter markers or declare args explicitly"
                );
            } else {
                rducks_format_error_message(err, err_cap, "unsupported dynamic Rducks argument type id %d", (int)type_id);
            }
            return 0;
        }
        desc = rducks_type_desc_new(RDUCKS_KIND_SCALAR);
        if (!desc) goto oom;
        desc->scalar = scalar;
        *out = desc;
        return 1;
    }

oom:
    rducks_format_error_message(err, err_cap, "out of memory resolving dynamic Rducks argument type");
fail:
    rducks_type_desc_destroy(desc);
    return 0;
}

static int rducks_parse_null_handling(const char *text, rducks_null_handling_t *out, char *err, size_t err_cap) {
    char token[32];
    size_t len;
    if (!text || !out) {
        rducks_format_error_message(err, err_cap, "invalid null_handling value");
        return 0;
    }
    while (*text == ' ' || *text == '\t' || *text == '\n' || *text == '\r') {
        text++;
    }
    len = strlen(text);
    while (len > 0 && (text[len - 1U] == ' ' || text[len - 1U] == '\t' || text[len - 1U] == '\n' ||
                       text[len - 1U] == '\r')) {
        len--;
    }
    if (len == 0 || len >= sizeof(token)) {
        rducks_format_error_message(err, err_cap, "invalid null_handling value");
        return 0;
    }
    memcpy(token, text, len);
    token[len] = '\0';
    rducks_ascii_lower_inplace(token);
    if (strcmp(token, "default") == 0 || strcmp(token, "null_in_null_out") == 0) {
        *out = RDUCKS_NULL_DEFAULT;
        return 1;
    }
    if (strcmp(token, "special") == 0) {
        *out = RDUCKS_NULL_SPECIAL;
        return 1;
    }
    rducks_format_error_message(err, err_cap, "unsupported null_handling value: %s", token);
    return 0;
}

static int rducks_parse_exception_handling(const char *text, rducks_exception_handling_t *out, char *err,
                                           size_t err_cap) {
    char token[32];
    size_t len;
    if (!text || !out) {
        rducks_format_error_message(err, err_cap, "invalid exception_handling value");
        return 0;
    }
    while (*text == ' ' || *text == '\t' || *text == '\n' || *text == '\r') {
        text++;
    }
    len = strlen(text);
    while (len > 0 && (text[len - 1U] == ' ' || text[len - 1U] == '\t' || text[len - 1U] == '\n' ||
                       text[len - 1U] == '\r')) {
        len--;
    }
    if (len == 0 || len >= sizeof(token)) {
        rducks_format_error_message(err, err_cap, "invalid exception_handling value");
        return 0;
    }
    memcpy(token, text, len);
    token[len] = '\0';
    rducks_ascii_lower_inplace(token);
    if (strcmp(token, "rethrow") == 0 || strcmp(token, "error") == 0) {
        *out = RDUCKS_EXCEPTION_RETHROW;
        return 1;
    }
    if (strcmp(token, "return_null") == 0 || strcmp(token, "return-null") == 0) {
        *out = RDUCKS_EXCEPTION_RETURN_NULL;
        return 1;
    }
    rducks_format_error_message(err, err_cap, "unsupported exception_handling value: %s", token);
    return 0;
}

static int rducks_parse_eval_mode(const char *text, rducks_eval_mode_t *out, char *err, size_t err_cap) {
    char token[16];
    size_t len;
    if (!text || !out) {
        rducks_format_error_message(err, err_cap, "invalid eval_mode value");
        return 0;
    }
    while (*text == ' ' || *text == '\t' || *text == '\n' || *text == '\r') {
        text++;
    }
    len = strlen(text);
    while (len > 0 && (text[len - 1U] == ' ' || text[len - 1U] == '\t' || text[len - 1U] == '\n' ||
                       text[len - 1U] == '\r')) {
        len--;
    }
    if (len == 0 || len >= sizeof(token)) {
        rducks_format_error_message(err, err_cap, "invalid eval_mode value");
        return 0;
    }
    memcpy(token, text, len);
    token[len] = '\0';
    rducks_ascii_lower_inplace(token);
    if (strcmp(token, "r") == 0) {
        *out = RDUCKS_EVAL_R;
        return 1;
    }
    if (strcmp(token, "rc") == 0) {
        *out = RDUCKS_EVAL_RC;
        return 1;
    }
    if (strcmp(token, "rcv") == 0) {
        *out = RDUCKS_EVAL_RCV;
        return 1;
    }
    if (strcmp(token, "ripc") == 0) {
        *out = RDUCKS_EVAL_RIPC;
        return 1;
    }
    rducks_format_error_message(err, err_cap, "unsupported eval_mode value: %s", token);
    return 0;
}

static int rducks_parse_type_list(const char *text, rducks_type_desc_t ***out, size_t *out_count, char *err, size_t err_cap) {
    char *copy;
    char *cursor;
    rducks_type_desc_t **items = NULL;
    size_t count = 0;
    size_t capacity = 0;
    if (!text || !out || !out_count) {
        rducks_format_error_message(err, err_cap, "invalid type list");
        return 0;
    }
    *out = NULL;
    *out_count = 0;
    if (text[0] == '\0') return 1;
    copy = rducks_strdup(text);
    if (!copy) {
        rducks_format_error_message(err, err_cap, "out of memory");
        return 0;
    }
    cursor = copy;
    while (cursor && *cursor) {
        char *next;
        size_t part_len;
        rducks_type_desc_t *desc = NULL;
        next = (char *)rducks_find_top_level_char_len(cursor, strlen(cursor), ',');
        if (next) {
            *next = '\0';
            next++;
        }
        part_len = strlen(cursor);
        if (!rducks_parse_type_desc_len(cursor, part_len, &desc, err, err_cap)) {
            for (size_t i = 0; i < count; i++) rducks_type_desc_destroy(items[i]);
            free(items);
            free(copy);
            return 0;
        }
        if (count == capacity) {
            size_t new_capacity = capacity == 0U ? 4U : capacity * 2U;
            rducks_type_desc_t **new_items;
            if (new_capacity <= capacity || new_capacity > (SIZE_MAX / sizeof(rducks_type_desc_t *))) {
                rducks_format_error_message(err, err_cap, "UDF argument list is too large to allocate");
                rducks_type_desc_destroy(desc);
                for (size_t i = 0; i < count; i++) rducks_type_desc_destroy(items[i]);
                free(items);
                free(copy);
                return 0;
            }
            new_items = (rducks_type_desc_t **)rducks_realloc_array(items, new_capacity, sizeof(*new_items));
            if (!new_items) {
                rducks_format_error_message(err, err_cap, "out of memory");
                rducks_type_desc_destroy(desc);
                for (size_t i = 0; i < count; i++) rducks_type_desc_destroy(items[i]);
                free(items);
                free(copy);
                return 0;
            }
            items = new_items;
            capacity = new_capacity;
        }
        items[count++] = desc;
        cursor = next;
    }
    free(copy);
    *out = items;
    *out_count = count;
    return 1;
}

