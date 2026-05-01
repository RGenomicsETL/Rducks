/* Included by ../rducks_extension.c. */

#ifdef _WIN32
static SRWLOCK g_main_thread_token_lock = SRWLOCK_INIT;
static void rducks_main_thread_token_lock_write(void) { AcquireSRWLockExclusive(&g_main_thread_token_lock); }
static void rducks_main_thread_token_unlock_write(void) { ReleaseSRWLockExclusive(&g_main_thread_token_lock); }
static void rducks_main_thread_token_lock_read(void) { AcquireSRWLockShared(&g_main_thread_token_lock); }
static void rducks_main_thread_token_unlock_read(void) { ReleaseSRWLockShared(&g_main_thread_token_lock); }
#else
static pthread_mutex_t g_main_thread_token_lock = PTHREAD_MUTEX_INITIALIZER;
static void rducks_main_thread_token_lock_write(void) { pthread_mutex_lock(&g_main_thread_token_lock); }
static void rducks_main_thread_token_unlock_write(void) { pthread_mutex_unlock(&g_main_thread_token_lock); }
static void rducks_main_thread_token_lock_read(void) { pthread_mutex_lock(&g_main_thread_token_lock); }
static void rducks_main_thread_token_unlock_read(void) { pthread_mutex_unlock(&g_main_thread_token_lock); }
#endif

static void rducks_current_thread_token(char *buf, size_t cap) {
    if (!buf || cap == 0U) return;
#ifdef _WIN32
    snprintf(buf, cap, "win:%lu", (unsigned long)GetCurrentThreadId());
#else
    pthread_t self = pthread_self();
    unsigned char bytes[sizeof(self)];
    size_t pos = 0;
    memcpy(bytes, &self, sizeof(self));
    pos += (size_t)snprintf(buf + pos, cap - pos, "posix:");
    for (size_t i = 0; i < sizeof(self) && pos + 2U < cap; i++) {
        pos += (size_t)snprintf(buf + pos, cap - pos, "%02x", bytes[i]);
    }
#endif
    buf[cap - 1U] = '\0';
}

static void rducks_set_main_thread_token(const char *token) {
    rducks_main_thread_token_lock_write();
    snprintf(g_main_thread_token, sizeof(g_main_thread_token), "%s", token ? token : "");
    g_main_thread_token_set = token && token[0];
    rducks_main_thread_token_unlock_write();
}

static int rducks_get_main_thread_token(char *buf, size_t cap) {
    int out;
    if (!buf || cap == 0U) return 0;
    rducks_main_thread_token_lock_read();
    out = g_main_thread_token_set;
    if (out) {
        snprintf(buf, cap, "%s", g_main_thread_token);
    }
    rducks_main_thread_token_unlock_read();
    if (out) buf[cap - 1U] = '\0';
    return out;
}

static void rducks_capture_main_thread(void) {
    /* DuckDB may run extension loading on a worker thread. The R package passes
     * the calling R thread token explicitly through rducks_set_main_thread_token()
     * during rducks_enable(). */
}

