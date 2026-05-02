/* Included by ../rducks_extension.c. */

/* Registration-time scalar token parser.  Execution marshalling goes through
 * DuckDB Arrow C Data + nanoarrow, not this token switch.
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
    if (duckdb_type_id == DUCKDB_TYPE_INVALID) {
        return NULL;
    }
    return duckdb_create_logical_type(duckdb_type_id);
}

static char *rducks_strdup_len(const char *x, size_t len) {
    char *out = (char *)malloc(len + 1U);
    if (!out) return NULL;
    memcpy(out, x, len);
    out[len] = '\0';
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
    free(desc);
}

static rducks_type_desc_t *rducks_type_desc_new(rducks_type_kind_t kind) {
    rducks_type_desc_t *desc = (rducks_type_desc_t *)calloc(1, sizeof(rducks_type_desc_t));
    if (desc) desc->kind = kind;
    return desc;
}

static int rducks_parse_type_desc_text(const char *text, rducks_type_desc_t **out, char *err, size_t err_cap);

static int rducks_parse_type_desc_len(const char *text, size_t len, rducks_type_desc_t **out, char *err, size_t err_cap) {
    char *copy = rducks_strdup_trimmed_len(text, len);
    int ok;
    if (!copy) {
        snprintf(err, err_cap, "out of memory");
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
            snprintf(err, err_cap, "decimal type must be decimal<width;scale>");
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
            snprintf(err, err_cap, "invalid decimal width");
            return 0;
        }
        scale = strtol(scale_text, &endp, 10);
        if (!endp || *endp != '\0') {
            free(width_text);
            free(scale_text);
            snprintf(err, err_cap, "invalid decimal scale");
            return 0;
        }
        free(width_text);
        free(scale_text);
        if (width < 1 || width > 38 || scale < 0 || scale > width) {
            snprintf(err, err_cap, "invalid decimal width or scale");
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
                new_names = (char **)realloc(desc->field_names, sizeof(char *) * new_cap);
                if (!new_names) goto oom;
                desc->field_names = new_names;
                for (size_t j = cap; j < new_cap; j++) desc->field_names[j] = NULL;
                cap = new_cap;
            }
            level = rducks_strdup_trimmed_len(cursor, part_len);
            if (!level) goto oom;
            if (!level[0]) {
                free(level);
                snprintf(err, err_cap, "enum levels must be non-empty");
                goto fail;
            }
            desc->field_names[count++] = level;
            desc->field_count = count;
            if (!sep) break;
            cursor = sep + 1;
            remain = inner_len - (size_t)(cursor - inner);
        }
        if (desc->field_count == 0) {
            snprintf(err, err_cap, "enum type must contain at least one level");
            goto fail;
        }
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
                snprintf(err, err_cap, "union members must be name:type");
                goto fail;
            }
            if (count == cap) {
                size_t new_cap = cap == 0 ? 4U : cap * 2U;
                char **new_names;
                rducks_type_desc_t **new_types;
                if (new_cap <= cap) goto oom;
                new_names = (char **)realloc(desc->field_names, sizeof(char *) * new_cap);
                if (!new_names) goto oom;
                desc->field_names = new_names;
                new_types = (rducks_type_desc_t **)realloc(desc->field_types, sizeof(rducks_type_desc_t *) * new_cap);
                if (!new_types) goto oom;
                desc->field_types = new_types;
                for (size_t j = cap; j < new_cap; j++) {
                    desc->field_names[j] = NULL;
                    desc->field_types[j] = NULL;
                }
                cap = new_cap;
            }
            desc->field_names[count] = rducks_strdup_trimmed_len(cursor, (size_t)(colon - cursor));
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
            snprintf(err, err_cap, "union type must contain 1 to 255 members");
            goto fail;
        }
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
            snprintf(err, err_cap, "map type must be map<key;value>");
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
                snprintf(err, err_cap, "struct fields must be name:type");
                goto fail;
            }
            if (count == cap) {
                size_t new_cap = cap == 0 ? 4U : cap * 2U;
                char **new_names;
                rducks_type_desc_t **new_types;
                if (new_cap <= cap) goto oom;
                new_names = (char **)realloc(desc->field_names, sizeof(char *) * new_cap);
                if (!new_names) goto oom;
                desc->field_names = new_names;
                new_types = (rducks_type_desc_t **)realloc(desc->field_types, sizeof(rducks_type_desc_t *) * new_cap);
                if (!new_types) goto oom;
                desc->field_types = new_types;
                for (size_t j = cap; j < new_cap; j++) {
                    desc->field_names[j] = NULL;
                    desc->field_types[j] = NULL;
                }
                cap = new_cap;
            }
            desc->field_names[count] = rducks_strdup_trimmed_len(cursor, (size_t)(colon - cursor));
            if (!desc->field_names[count]) goto oom;
            if (!rducks_parse_type_desc_len(colon + 1, part_len - (size_t)(colon - cursor) - 1U, &desc->field_types[count], err, err_cap)) goto fail;
            count++;
            desc->field_count = count;
            if (!sep) break;
            cursor = sep + 1;
            remain = inner_len - (size_t)(cursor - inner);
        }
        if (desc->field_count == 0) {
            snprintf(err, err_cap, "struct type must contain at least one field");
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
                snprintf(err, err_cap, "invalid array size");
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
            snprintf(err, err_cap, "unsupported Rducks type: %s", text);
            return 0;
        }
        desc = rducks_type_desc_new(RDUCKS_KIND_SCALAR);
        if (!desc) goto oom;
        desc->scalar = scalar;
        *out = desc;
        return 1;
    }

oom:
    snprintf(err, err_cap, "out of memory");
fail:
    rducks_type_desc_destroy(desc);
    return 0;
}

static duckdb_logical_type rducks_create_logical_type_for_desc(const rducks_type_desc_t *desc) {
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
        if (!child || desc->array_size == 0) return NULL;
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
        if (desc->field_count == 0 || desc->field_count > (SIZE_MAX / sizeof(duckdb_logical_type))) return NULL;
        types = (duckdb_logical_type *)calloc(desc->field_count, sizeof(duckdb_logical_type));
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
        if (desc->field_count == 0) return NULL;
        return duckdb_create_enum_type((const char **)desc->field_names, (idx_t)desc->field_count);
    }
    if (desc->kind == RDUCKS_KIND_UNION) {
        duckdb_logical_type *types;
        duckdb_logical_type out = NULL;
        if (desc->field_count == 0 || desc->field_count > 255U || desc->field_count > (SIZE_MAX / sizeof(duckdb_logical_type))) return NULL;
        types = (duckdb_logical_type *)calloc(desc->field_count, sizeof(duckdb_logical_type));
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

static int rducks_parse_null_handling(const char *text, rducks_null_handling_t *out, char *err, size_t err_cap) {
    char token[32];
    size_t len;
    if (!text || !out) {
        snprintf(err, err_cap, "invalid null_handling value");
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
        snprintf(err, err_cap, "invalid null_handling value");
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
    snprintf(err, err_cap, "unsupported null_handling value: %s", token);
    return 0;
}

static int rducks_parse_exception_handling(const char *text, rducks_exception_handling_t *out, char *err,
                                           size_t err_cap) {
    char token[32];
    size_t len;
    if (!text || !out) {
        snprintf(err, err_cap, "invalid exception_handling value");
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
        snprintf(err, err_cap, "invalid exception_handling value");
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
    snprintf(err, err_cap, "unsupported exception_handling value: %s", token);
    return 0;
}

static int rducks_parse_eval_mode(const char *text, rducks_eval_mode_t *out, char *err, size_t err_cap) {
    char token[16];
    size_t len;
    if (!text || !out) {
        snprintf(err, err_cap, "invalid eval_mode value");
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
        snprintf(err, err_cap, "invalid eval_mode value");
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
    snprintf(err, err_cap, "unsupported eval_mode value: %s", token);
    return 0;
}

static int rducks_parse_type_list(const char *text, rducks_type_desc_t ***out, size_t *out_count, char *err, size_t err_cap) {
    char *copy;
    char *cursor;
    rducks_type_desc_t **items = NULL;
    size_t count = 0;
    size_t capacity = 0;
    if (!text || !out || !out_count) {
        snprintf(err, err_cap, "invalid type list");
        return 0;
    }
    *out = NULL;
    *out_count = 0;
    if (text[0] == '\0') return 1;
    copy = (char *)malloc(strlen(text) + 1U);
    if (!copy) {
        snprintf(err, err_cap, "out of memory");
        return 0;
    }
    strcpy(copy, text);
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
                snprintf(err, err_cap, "UDF argument list is too large to allocate");
                rducks_type_desc_destroy(desc);
                for (size_t i = 0; i < count; i++) rducks_type_desc_destroy(items[i]);
                free(items);
                free(copy);
                return 0;
            }
            new_items = (rducks_type_desc_t **)realloc(items, sizeof(rducks_type_desc_t *) * new_capacity);
            if (!new_items) {
                snprintf(err, err_cap, "out of memory");
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

