/* Included by ../rducks_extension.c. */

static char *rducks_copy_duckdb_string(duckdb_string_t *s) {
    uint32_t len = duckdb_string_t_length(*s);
    const char *data = duckdb_string_t_data(s);
    char *out = (char *)malloc((size_t)len + 1U);
    if (!out) {
        return NULL;
    }
    memcpy(out, data, (size_t)len);
    out[len] = '\0';
    return out;
}

static void rducks_ascii_lower_inplace(char *x) {
    for (; x && *x; ++x) {
        if (*x >= 'A' && *x <= 'Z') {
            *x = (char)(*x - 'A' + 'a');
        }
    }
}

