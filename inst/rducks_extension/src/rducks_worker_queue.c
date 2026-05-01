/* Included by ../rducks_extension.c. */

static int rducks_is_main_thread(void) {
    char current[128];
    char expected[128];
    if (!rducks_get_main_thread_token(expected, sizeof(expected))) return 0;
    rducks_current_thread_token(current, sizeof(current));
    return strcmp(current, expected) == 0;
}

static int rducks_allow_direct_r_execution(char *err, size_t err_cap) {
    if (!rducks_is_main_thread()) {
        snprintf(err, err_cap, "direct Rducks R execution reached a non-main DuckDB execution thread");
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

typedef struct rducks_thread_stats {
    unsigned long long udf_entries_main;
    unsigned long long udf_entries_worker;
    unsigned long long queued_requests;
    unsigned long long drained_requests;
    unsigned long long r_execute_main;
    unsigned long long r_execute_off_main;
    unsigned long long current_queue_depth;
    unsigned long long max_queue_depth;
} rducks_thread_stats_t;

static rducks_thread_stats_t g_thread_stats;

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

static void rducks_thread_stats_reset(void) {
    rducks_request_lock();
    memset(&g_thread_stats, 0, sizeof(g_thread_stats));
    rducks_request_unlock();
}

static void rducks_thread_stats_format(char *buf, size_t cap) {
    rducks_thread_stats_t stats;
    if (!buf || cap == 0U) return;
    rducks_request_lock();
    stats = g_thread_stats;
    rducks_request_unlock();
    snprintf(buf, cap,
             "udf_entries_main=%llu,udf_entries_worker=%llu,queued_requests=%llu,drained_requests=%llu,"
             "r_execute_main=%llu,r_execute_off_main=%llu,current_queue_depth=%llu,max_queue_depth=%llu",
             stats.udf_entries_main, stats.udf_entries_worker, stats.queued_requests, stats.drained_requests,
             stats.r_execute_main, stats.r_execute_off_main, stats.current_queue_depth, stats.max_queue_depth);
    buf[cap - 1U] = '\0';
}

static void rducks_stats_note_udf_entry(int is_main) {
    rducks_request_lock();
    if (is_main) {
        g_thread_stats.udf_entries_main++;
    } else {
        g_thread_stats.udf_entries_worker++;
    }
    rducks_request_unlock();
}

static void rducks_stats_note_r_execute(int is_main) {
    rducks_request_lock();
    if (is_main) {
        g_thread_stats.r_execute_main++;
    } else {
        g_thread_stats.r_execute_off_main++;
    }
    rducks_request_unlock();
}

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
    g_thread_stats.queued_requests++;
    g_thread_stats.current_queue_depth++;
    if (g_thread_stats.current_queue_depth > g_thread_stats.max_queue_depth) {
        g_thread_stats.max_queue_depth = g_thread_stats.current_queue_depth;
    }
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
        if (g_thread_stats.current_queue_depth > 0) {
            g_thread_stats.current_queue_depth--;
        }
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
        rducks_request_lock();
        g_thread_stats.drained_requests++;
        rducks_request_unlock();
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

