/* Included by ../rducks_extension.c. */

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

static void rducks_set_main_thread_token(rducks_runtime_entry_t *runtime, const char *token) {
    if (!runtime) return;
    rducks_runtime_lock();
    snprintf(runtime->main_thread_token, sizeof(runtime->main_thread_token), "%s", token ? token : "");
    runtime->main_thread_token_set = token && token[0];
    rducks_runtime_unlock();
}

static int rducks_get_main_thread_token(rducks_runtime_entry_t *runtime, char *buf, size_t cap) {
    int out;
    if (!runtime || !buf || cap == 0U) return 0;
    rducks_runtime_lock();
    out = runtime->main_thread_token_set;
    if (out) {
        snprintf(buf, cap, "%s", runtime->main_thread_token);
    }
    rducks_runtime_unlock();
    if (out) buf[cap - 1U] = '\0';
    return out;
}
