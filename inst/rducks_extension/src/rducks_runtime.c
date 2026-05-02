/* Included by ../rducks_extension.c. */

static int rducks_is_main_thread(void) {
    char current[128];
    char expected[128];
    if (!rducks_get_main_thread_token(expected, sizeof(expected))) return 0;
    rducks_current_thread_token(current, sizeof(current));
    return strcmp(current, expected) == 0;
}

static int rducks_allow_calling_thread_r_execution(char *err, size_t err_cap) {
    if (!rducks_is_main_thread()) {
        snprintf(err, err_cap, "Rducks R execution reached a non-calling DuckDB execution thread");
        return 0;
    }
    return 1;
}

static void rducks_r_scalar_meta_destroy(void *ptr) {
    rducks_r_scalar_meta_t *meta = (rducks_r_scalar_meta_t *)ptr;
    if (!meta) {
        return;
    }
    if (meta->fun && meta->fun != R_NilValue && rducks_is_main_thread()) {
        R_ReleaseObject(meta->fun);
    }
    /* Without a calling-R-thread release queue, an off-main DuckDB destructor
     * cannot safely call R_ReleaseObject(). Prefer a preserved-object leak over
     * an unsafe off-main R API call. */
    if (meta->args) {
        for (size_t i = 0; i < meta->arity; i++) rducks_type_desc_destroy(meta->args[i]);
    }
    free(meta->args);
    rducks_type_desc_destroy(meta->return_desc);
    free(meta);
}
