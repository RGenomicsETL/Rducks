/* Included by ../rducks_extension.c. */

static int rducks_is_recorded_main_thread(rducks_runtime_entry_t *runtime);

static int rducks_set_main_thread_token(rducks_runtime_entry_t *runtime, const char *token) {
    if (!runtime || !token || !token[0]) return 0;
#ifdef _WIN32
    const char *prefix = "win:";
    char *end = NULL;
    unsigned long value;
    if (strncmp(token, prefix, strlen(prefix)) != 0) return 0;
    errno = 0;
    value = strtoul(token + strlen(prefix), &end, 10);
    if (errno != 0 || !end || *end != '\0') return 0;
    rducks_runtime_lock();
    if (runtime->main_thread_token_set && strcmp(runtime->main_thread_token, token) != 0) {
        rducks_runtime_unlock();
        return 0;
    }
    snprintf(runtime->main_thread_token, sizeof(runtime->main_thread_token), "%s", token);
    runtime->main_thread_id = (DWORD)value;
    runtime->main_thread_token_set = 1;
    rducks_runtime_unlock();
    return 1;
#else
    const char *prefix = "posix-pthread-ptr:";
    char *end = NULL;
    unsigned long long value;
    const pthread_t *thread_id;
    if (strncmp(token, prefix, strlen(prefix)) != 0) return 0;
    errno = 0;
    value = strtoull(token + strlen(prefix), &end, 10);
    if (errno != 0 || !end || *end != '\0' || value == 0ULL) return 0;
    thread_id = (const pthread_t *)(uintptr_t)value;
    rducks_runtime_lock();
    if (runtime->main_thread_token_set && strcmp(runtime->main_thread_token, token) != 0) {
        rducks_runtime_unlock();
        return 0;
    }
    snprintf(runtime->main_thread_token, sizeof(runtime->main_thread_token), "%s", token);
    runtime->main_thread_id = thread_id;
    runtime->main_thread_token_set = 1;
    rducks_runtime_unlock();
    return 1;
#endif
}

static int rducks_authorize_main_thread_payload(rducks_runtime_entry_t *runtime,
                                                char *payload, const char **value_out) {
    char *sep;
    int ok = 0;
    if (value_out) *value_out = NULL;
    if (!runtime || !payload || !value_out) return 0;
    sep = strchr(payload, '\n');
    if (!sep || sep == payload || !sep[1]) return 0;
    *sep = '\0';
    rducks_runtime_lock();
    ok = runtime->main_thread_token_set && strcmp(runtime->main_thread_token, payload) == 0;
    rducks_runtime_unlock();
    if (!ok || !rducks_is_recorded_main_thread(runtime)) return 0;
    *value_out = sep + 1;
    return 1;
}

static int rducks_is_recorded_main_thread(rducks_runtime_entry_t *runtime) {
    int token_set;
#ifdef _WIN32
    DWORD main_thread_id;
#else
    const pthread_t *main_thread_id;
#endif
    if (!runtime) return 0;
    rducks_runtime_lock();
    token_set = runtime->main_thread_token_set;
    if (token_set) {
        main_thread_id = runtime->main_thread_id;
    }
    rducks_runtime_unlock();
    if (!token_set) return 0;
#ifdef _WIN32
    return GetCurrentThreadId() == main_thread_id;
#else
    if (!main_thread_id) return 0;
    return pthread_equal(pthread_self(), *main_thread_id) != 0;
#endif
}
