/* Included by ../rducks_extension.c. */

static int rducks_is_main_thread(void) {
    char current[128];
    char expected[128];
    if (!rducks_get_main_thread_token(expected, sizeof(expected))) return 0;
    rducks_current_thread_token(current, sizeof(current));
    return strcmp(current, expected) == 0;
}

static int rducks_allow_direct_r_callback(char *err, size_t err_cap) {
    if (!rducks_is_main_thread()) {
        snprintf(err, err_cap, "direct Rducks callbacks reached a non-main DuckDB execution thread");
        return 0;
    }
    return 1;
}

typedef struct rducks_udf_request {
    rducks_r_scalar_meta_t *meta;
    duckdb_data_chunk input;
    duckdb_vector output;
    int done;
    int ok;
    char err[256];
    struct rducks_udf_request *next;
} rducks_udf_request_t;

static rducks_udf_request_t *g_request_head = NULL;
static rducks_udf_request_t *g_request_tail = NULL;
static int g_request_pump_depth = 0;

#ifdef _WIN32
static SRWLOCK g_request_lock = SRWLOCK_INIT;
static CONDITION_VARIABLE g_request_cv = CONDITION_VARIABLE_INIT;
static void rducks_request_lock(void) { AcquireSRWLockExclusive(&g_request_lock); }
static void rducks_request_unlock(void) { ReleaseSRWLockExclusive(&g_request_lock); }
static void rducks_request_wait(void) { SleepConditionVariableSRW(&g_request_cv, &g_request_lock, INFINITE, 0); }
static void rducks_request_signal(void) { WakeAllConditionVariable(&g_request_cv); }
#else
static pthread_mutex_t g_request_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_request_cv = PTHREAD_COND_INITIALIZER;
static void rducks_request_lock(void) { pthread_mutex_lock(&g_request_lock); }
static void rducks_request_unlock(void) { pthread_mutex_unlock(&g_request_lock); }
static void rducks_request_wait(void) { pthread_cond_wait(&g_request_cv, &g_request_lock); }
static void rducks_request_signal(void) { pthread_cond_broadcast(&g_request_cv); }
#endif

static int rducks_r_scalar_execute(rducks_r_scalar_meta_t *meta, duckdb_data_chunk input, duckdb_vector output,
                                   char *err, size_t err_cap);

static void rducks_request_enqueue_and_wait(rducks_udf_request_t *req) {
    req->done = 0;
    req->ok = 0;
    req->err[0] = '\0';
    req->next = NULL;

    rducks_request_lock();
    if (g_request_tail) {
        g_request_tail->next = req;
    } else {
        g_request_head = req;
    }
    g_request_tail = req;
    rducks_request_signal();
    while (!req->done) {
        rducks_request_wait();
    }
    rducks_request_unlock();
}

static rducks_udf_request_t *rducks_request_pop(void) {
    rducks_udf_request_t *req;
    rducks_request_lock();
    req = g_request_head;
    if (req) {
        g_request_head = req->next;
        if (!g_request_head) g_request_tail = NULL;
        req->next = NULL;
    }
    rducks_request_unlock();
    return req;
}

static void rducks_request_finish(rducks_udf_request_t *req) {
    rducks_request_lock();
    req->done = 1;
    rducks_request_signal();
    rducks_request_unlock();
}

static int rducks_drain_worker_requests(void) {
    int count = 0;
    if (!rducks_is_main_thread() || g_request_pump_depth) return 0;
    g_request_pump_depth++;
    for (;;) {
        rducks_udf_request_t *req = rducks_request_pop();
        if (!req) break;
        req->ok = rducks_r_scalar_execute(req->meta, req->input, req->output, req->err, sizeof(req->err));
        rducks_request_finish(req);
        count++;
    }
    g_request_pump_depth--;
    return count;
}

static void rducks_r_scalar_meta_destroy(void *ptr) {
    rducks_r_scalar_meta_t *meta = (rducks_r_scalar_meta_t *)ptr;
    if (!meta) {
        return;
    }
    if (meta->fun && meta->fun != R_NilValue && rducks_is_main_thread()) {
        R_ReleaseObject(meta->fun);
    }
    /* Without the future main-thread pump, an off-main DuckDB destructor cannot
     * safely call R_ReleaseObject(). Prefer a preserved-object leak over an
     * unsafe off-main R API call. */
    if (meta->args) {
        for (size_t i = 0; i < meta->arity; i++) rducks_type_desc_destroy(meta->args[i]);
    }
    free(meta->args);
    rducks_type_desc_destroy(meta->return_desc);
    free(meta);
}

static void rducks_inactive_scalar_meta_destroy(void *ptr) {
    rducks_inactive_scalar_meta_t *meta = (rducks_inactive_scalar_meta_t *)ptr;
    if (!meta) return;
    free(meta->name);
    free(meta);
}

static void rducks_inactive_scalar_udf(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    (void)input;
    (void)output;
    rducks_inactive_scalar_meta_t *meta =
        (rducks_inactive_scalar_meta_t *)duckdb_scalar_function_get_extra_info(info);
    char err[256];
    if (meta && meta->name) {
        snprintf(err, sizeof(err), "Rducks UDF %s has been unregistered", meta->name);
    } else {
        snprintf(err, sizeof(err), "Rducks UDF has been unregistered");
    }
    duckdb_scalar_function_set_error(info, err);
}

