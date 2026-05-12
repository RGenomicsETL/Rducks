/* Included by ../rducks_extension.c. */

static char *rducks_strdup_len(const char *x, size_t len) {
    char *out;
    if (len == SIZE_MAX || (!x && len != 0U)) return NULL;
    out = (char *)malloc(len + 1U);
    if (!out) return NULL;
    if (len != 0U) memcpy(out, x, len);
    out[len] = '\0';
    return out;
}

static char *rducks_strdup(const char *s) {
    if (!s) return NULL;
    return rducks_strdup_len(s, strlen(s));
}

static char *rducks_copy_duckdb_string(duckdb_string_t *s) {
    uint32_t len = duckdb_string_t_length(*s);
    const char *data = duckdb_string_t_data(s);
    return rducks_strdup_len(data, (size_t)len);
}

static void rducks_ascii_lower_inplace(char *x) {
    for (; x && *x; ++x) {
        if (*x >= 'A' && *x <= 'Z') {
            *x = (char)(*x - 'A' + 'a');
        }
    }
}

