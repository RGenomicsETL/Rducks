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

static void rducks_mark_error_truncated(char *out, size_t out_cap) {
    static const char suffix[] = " ... [truncated]";
    size_t suffix_len = sizeof(suffix) - 1U;
    if (!out || out_cap == 0U || out_cap <= suffix_len + 1U) return;
    memcpy(out + out_cap - suffix_len - 1U, suffix, suffix_len);
    out[out_cap - 1U] = '\0';
}

static void rducks_copy_error_message(char *out, size_t out_cap,
                                      const char *message, const char *fallback) {
    const char *text = (message && message[0]) ? message : (fallback ? fallback : "Rducks error");
    size_t len;
    if (!out || out_cap == 0U) return;
    len = strlen(text);
    if (len < out_cap) {
        memcpy(out, text, len + 1U);
        return;
    }
    /* Deliberate truncation: copy what fits, NUL-terminate, then mark. Done with
     * memcpy rather than snprintf to avoid a -Wformat-truncation diagnostic for
     * the intentionally-clipped copy. */
    memcpy(out, text, out_cap - 1U);
    out[out_cap - 1U] = '\0';
    rducks_mark_error_truncated(out, out_cap);
}

static int rducks_format_error_message(char *out, size_t out_cap, const char *fmt, ...) {
    va_list args;
    int needed;
    if (!out || out_cap == 0U) return -1;
    if (!fmt) {
        rducks_copy_error_message(out, out_cap, NULL, "Rducks error");
        return -1;
    }
    va_start(args, fmt);
    needed = vsnprintf(out, out_cap, fmt, args);
    va_end(args);
    if (needed < 0) {
        rducks_copy_error_message(out, out_cap, NULL, "Rducks error");
        return needed;
    }
    if ((size_t)needed >= out_cap) rducks_mark_error_truncated(out, out_cap);
    return needed;
}

