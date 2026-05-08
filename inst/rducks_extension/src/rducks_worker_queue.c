/* Included by ../rducks_extension.c. */

#define RDUCKS_QUEUE_ERROR_SIZE 512
#define RDUCKS_QUEUE_WAIT_MS 100U
#define RDUCKS_QUEUE_TIMEOUT_TICKS 300U
#define RDUCKS_QUEUE_PENDING_TIMEOUT_MS ((uint64_t)RDUCKS_QUEUE_WAIT_MS * (uint64_t)RDUCKS_QUEUE_TIMEOUT_TICKS)
static int rducks_queue_sleep_ms(unsigned int ms);

typedef enum rducks_udf_request_state {
    RDUCKS_REQUEST_PENDING = 0,
    RDUCKS_REQUEST_RUNNING = 1,
    RDUCKS_REQUEST_DONE = 2,
    RDUCKS_REQUEST_CANCELLED = 3
} rducks_udf_request_state_t;

typedef int (*rducks_queue_execute_request_fn)(rducks_udf_request_t *request, char *err_msg, size_t err_cap);

struct rducks_udf_request {
    rducks_udf_request_t *next;
    rducks_runtime_entry_t *runtime;
    rducks_queue_execute_request_fn execute;
    void *data;
    rducks_r_scalar_meta_t *meta;
    duckdb_data_chunk input;
    duckdb_vector output;
    rducks_rc_owned_result_payload_t *rc_result_payload;
    duckdb_data_chunk rc_result_chunk;
    rducks_udf_request_state_t state;
    int ok;
    char error[RDUCKS_QUEUE_ERROR_SIZE];
};

/* Queue lock discipline: do not call rducks_runtime_lock() while holding
 * runtime->queue_lock. Runtime counter/registry updates are performed before or
 * after queue critical sections to keep the lock graph acyclic.
 */
static void rducks_queue_lock(rducks_runtime_entry_t *runtime) {
#ifdef _WIN32
    EnterCriticalSection(&runtime->queue_lock);
#else
    pthread_mutex_lock(&runtime->queue_lock);
#endif
}

static void rducks_queue_unlock(rducks_runtime_entry_t *runtime) {
#ifdef _WIN32
    LeaveCriticalSection(&runtime->queue_lock);
#else
    pthread_mutex_unlock(&runtime->queue_lock);
#endif
}

static void rducks_queue_signal_all(rducks_runtime_entry_t *runtime) {
#ifdef _WIN32
    WakeAllConditionVariable(&runtime->queue_cond);
#else
    pthread_cond_broadcast(&runtime->queue_cond);
#endif
}

static int rducks_queue_wait_timed(rducks_runtime_entry_t *runtime, unsigned int ms) {
#ifdef _WIN32
    BOOL ok = SleepConditionVariableCS(&runtime->queue_cond, &runtime->queue_lock, (DWORD)ms);
    return ok ? 1 : 0;
#else
    struct timespec ts;
    long nsec;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) return 0;
    ts.tv_sec += (time_t)(ms / 1000U);
    nsec = ts.tv_nsec + (long)(ms % 1000U) * 1000000L;
    if (nsec >= 1000000000L) {
        ts.tv_sec += 1;
        nsec -= 1000000000L;
    }
    ts.tv_nsec = nsec;
    int rc = pthread_cond_timedwait(&runtime->queue_cond, &runtime->queue_lock, &ts);
    return rc != ETIMEDOUT;
#endif
}

static void rducks_queue_error_copy(char *dst, size_t dst_cap, const char *src, const char *default_msg) {
    const char *msg = (src && src[0]) ? src : default_msg;
    size_t n;
    if (!dst || dst_cap == 0U) return;
    if (!msg) msg = "Rducks queued scalar UDF request failed";
    n = strlen(msg);
    if (n >= dst_cap) n = dst_cap - 1U;
    memcpy(dst, msg, n);
    dst[n] = '\0';
}

static void rducks_queue_push_locked(rducks_runtime_entry_t *runtime, rducks_udf_request_t *request) {
    request->next = NULL;
    if (runtime->queue_tail) {
        runtime->queue_tail->next = request;
    } else {
        runtime->queue_head = request;
    }
    runtime->queue_tail = request;
}

static int rducks_queue_remove_pending_locked(rducks_runtime_entry_t *runtime, rducks_udf_request_t *request) {
    rducks_udf_request_t *prev = NULL;
    rducks_udf_request_t *cur = runtime->queue_head;
    while (cur) {
        if (cur == request) {
            if (prev) {
                prev->next = cur->next;
            } else {
                runtime->queue_head = cur->next;
            }
            if (runtime->queue_tail == cur) {
                runtime->queue_tail = prev;
            }
            cur->next = NULL;
            cur->state = RDUCKS_REQUEST_CANCELLED;
            if (runtime->queue_pending_current > 0) runtime->queue_pending_current--;
            return 1;
        }
        prev = cur;
        cur = cur->next;
    }
    return 0;
}

static rducks_udf_request_t *rducks_queue_pop_locked(rducks_runtime_entry_t *runtime) {
    rducks_udf_request_t *request = runtime->queue_head;
    while (request && request->state == RDUCKS_REQUEST_CANCELLED) {
        runtime->queue_head = request->next;
        if (runtime->queue_tail == request) runtime->queue_tail = NULL;
        request->next = NULL;
        request = runtime->queue_head;
    }
    if (!request) return NULL;
    runtime->queue_head = request->next;
    if (!runtime->queue_head) runtime->queue_tail = NULL;
    request->next = NULL;
    request->state = RDUCKS_REQUEST_RUNNING;
    if (runtime->queue_pending_current > 0) runtime->queue_pending_current--;
    runtime->queue_running_current++;
    if (runtime->queue_running_current > runtime->queue_running_max) {
        runtime->queue_running_max = runtime->queue_running_current;
    }
    return request;
}

static int rducks_queue_execute_scalar_on_main(rducks_udf_request_t *request, char *err_msg, size_t err_cap) {
    if (!request || !request->runtime || !request->meta) {
        snprintf(err_msg, err_cap, "Rducks queued scalar request is missing execution state");
        return 0;
    }
    if (request->meta->eval_mode == RDUCKS_EVAL_RC) {
        return rducks_rc_scalar_execute(request->runtime, request->meta, request->input,
                                       request->output, err_msg, err_cap);
    }
    if (request->meta->eval_mode == RDUCKS_EVAL_RCV) {
        return rducks_rc_vectorized_execute(request->runtime, request->meta, request->input,
                                           request->output, err_msg, err_cap);
    }
    if (request->meta->eval_mode == RDUCKS_EVAL_RIPC) {
        return rducks_ripc_execute(request->runtime, request->meta, request->input,
                                  request->output, err_msg, err_cap);
    }
    return rducks_r_scalar_execute(request->runtime, request->meta, request->input,
                                  request->output, err_msg, err_cap);
}

static int rducks_queue_execute_arrow_scalar_to_chunk_on_main(rducks_udf_request_t *request,
                                                              char *err_msg, size_t err_cap) {
    if (!request || !request->runtime || !request->meta) {
        snprintf(err_msg, err_cap, "Rducks queued Arrow/R owned-result request is missing execution state");
        return 0;
    }
    if (!rducks_is_main_thread(request->runtime)) {
        snprintf(err_msg, err_cap, "Rducks queued Arrow/R owned-result request reached a non-main thread");
        return 0;
    }
    if (request->rc_result_payload) {
        rducks_rc_owned_result_payload_free(request->rc_result_payload);
        request->rc_result_payload = NULL;
    }
    if (request->rc_result_chunk) {
        duckdb_destroy_data_chunk(&request->rc_result_chunk);
        request->rc_result_chunk = NULL;
    }
    return rducks_r_scalar_execute_to_owned_chunk(request->runtime, request->meta, request->input, request->output,
                                                 &request->rc_result_chunk, err_msg, err_cap);
}

static int rducks_queue_execute_rc_scalar_to_payload_on_main(rducks_udf_request_t *request,
                                                             char *err_msg, size_t err_cap) {
    if (!request || !request->runtime || !request->meta) {
        snprintf(err_msg, err_cap, "Rducks queued RC owned-result request is missing execution state");
        return 0;
    }
    if (!rducks_is_main_thread(request->runtime)) {
        snprintf(err_msg, err_cap, "Rducks queued RC owned-result request reached a non-main thread");
        return 0;
    }
    if (request->rc_result_payload) {
        rducks_rc_owned_result_payload_free(request->rc_result_payload);
        request->rc_result_payload = NULL;
    }
    if (request->rc_result_chunk) {
        duckdb_destroy_data_chunk(&request->rc_result_chunk);
        request->rc_result_chunk = NULL;
    }
    if (rducks_rc_owned_result_supported(request->meta)) {
        return rducks_rc_scalar_execute_to_owned_payload(request->runtime, request->meta, request->input, request->output,
                                                         &request->rc_result_payload, err_msg, err_cap);
    }
    return rducks_rc_scalar_execute_to_owned_chunk(request->runtime, request->meta, request->input, request->output,
                                                  &request->rc_result_chunk, err_msg, err_cap);
}

static int rducks_queue_execute_on_main(rducks_udf_request_t *request, char *err_msg, size_t err_cap) {
    if (!request || !request->runtime || !request->execute) {
        snprintf(err_msg, err_cap, "Rducks queued request is missing execution state");
        return 0;
    }
    if (!rducks_is_main_thread(request->runtime)) {
        snprintf(err_msg, err_cap, "Rducks queued request reached a non-main thread");
        return 0;
    }
    return request->execute(request, err_msg, err_cap);
}

static rducks_udf_request_t *rducks_queue_pop_request(rducks_runtime_entry_t *runtime) {
    rducks_udf_request_t *request;
    rducks_queue_lock(runtime);
    request = rducks_queue_pop_locked(runtime);
    rducks_queue_unlock(runtime);
    return request;
}

static int rducks_queue_submit_request(rducks_runtime_entry_t *runtime, rducks_udf_request_t *request,
                                       const char *timeout_msg, char *err_msg, size_t err_cap) {
    unsigned int ticks = 0;
    if (!runtime || !runtime->queue_initialized) {
        snprintf(err_msg, err_cap, "Rducks concurrent runtime queue is not initialized");
        return 0;
    }
    if (!request || !request->execute) {
        snprintf(err_msg, err_cap, "Rducks queued request is invalid");
        return 0;
    }

    request->runtime = runtime;
    request->next = NULL;
    request->state = RDUCKS_REQUEST_PENDING;
    request->ok = 0;
    request->error[0] = '\0';
    rducks_udf_record_queue_pending_add(request->meta);

    rducks_queue_lock(runtime);
    rducks_queue_push_locked(runtime, request);
    runtime->queue_submitted++;
    runtime->queue_pending_current++;
    if (runtime->queue_pending_current > runtime->queue_pending_max) {
        runtime->queue_pending_max = runtime->queue_pending_current;
    }
    rducks_queue_signal_all(runtime);

    while (request->state != RDUCKS_REQUEST_DONE) {
        rducks_queue_wait_timed(runtime, RDUCKS_QUEUE_WAIT_MS);
        if (request->state == RDUCKS_REQUEST_PENDING && ++ticks >= RDUCKS_QUEUE_TIMEOUT_TICKS) {
            if (rducks_queue_remove_pending_locked(runtime, request)) {
                runtime->queue_timeouts++;
                rducks_queue_signal_all(runtime);
                rducks_queue_unlock(runtime);
                rducks_udf_record_queue_pending_done(request->meta);
                snprintf(err_msg, err_cap, "%s", timeout_msg && timeout_msg[0] ? timeout_msg :
                         "Rducks timed out waiting for the recorded main R thread to drain a queued request");
                return 0;
            }
        }
    }

    int ok = request->ok;
    if (!ok) {
        rducks_queue_error_copy(err_msg, err_cap, request->error, "Rducks queued request failed");
    }
    rducks_queue_unlock(runtime);
    return ok;
}

static void rducks_queue_finish_request(rducks_runtime_entry_t *runtime, rducks_udf_request_t *request,
                                        int ok, const char *err_msg) {
    if (!runtime || !request) return;
    rducks_udf_record_queue_pending_done(request->meta);
    rducks_queue_lock(runtime);
    request->ok = ok;
    if (!ok) {
        rducks_queue_error_copy(request->error, sizeof(request->error), err_msg,
                                "Rducks queued scalar UDF request failed");
    }
    request->state = RDUCKS_REQUEST_DONE;
    runtime->queue_executed++;
    if (runtime->queue_running_current > 0) runtime->queue_running_current--;
    rducks_queue_signal_all(runtime);
    rducks_queue_unlock(runtime);
}

static int rducks_queue_submit_scalar(rducks_runtime_entry_t *runtime, rducks_r_scalar_meta_t *meta,
                                      duckdb_data_chunk input, duckdb_vector output,
                                      char *err_msg, size_t err_cap) {
    rducks_udf_request_t request;
    duckdb_data_chunk owned_input = NULL;
    int ok;
    if (!meta) {
        snprintf(err_msg, err_cap, "Rducks queued scalar metadata is missing");
        return 0;
    }

    memset(&request, 0, sizeof(request));
    if (meta->eval_mode == RDUCKS_EVAL_R) {
        request.execute = rducks_queue_execute_arrow_scalar_to_chunk_on_main;
    } else if (rducks_rc_owned_result_queue_supported(meta)) {
        request.execute = rducks_queue_execute_rc_scalar_to_payload_on_main;
    } else {
        request.execute = rducks_queue_execute_scalar_on_main;
    }
    request.meta = meta;
    request.input = input;
    request.output = output;

    if (rducks_rc_direct_input_snapshot_supported(meta)) {
        if (!rducks_rc_direct_input_snapshot_chunk(meta, input, &owned_input, err_msg, err_cap)) {
            return 0;
        }
        if (owned_input) {
            request.input = owned_input;
            rducks_udf_record_arrow_c_input_snapshot(meta);
        }
    }

    ok = rducks_queue_submit_request(runtime, &request,
        "Rducks timed out waiting for the recorded main R thread to drain a queued scalar UDF request",
        err_msg, err_cap);
    if (ok && request.rc_result_payload) {
        ok = rducks_rc_owned_result_payload_writeback(request.rc_result_payload, output, err_msg, err_cap);
    }
    if (ok && request.rc_result_chunk) {
        ok = rducks_rc_owned_result_chunk_writeback(request.rc_result_chunk, output, err_msg, err_cap);
    }
    if (request.rc_result_payload) {
        rducks_rc_owned_result_payload_free(request.rc_result_payload);
        request.rc_result_payload = NULL;
    }
    if (request.rc_result_chunk) {
        duckdb_destroy_data_chunk(&request.rc_result_chunk);
        request.rc_result_chunk = NULL;
    }
    if (owned_input) {
        duckdb_destroy_data_chunk(&owned_input);
        request.input = NULL;
    }
    return ok;
}

static int rducks_queue_sleep_ms(unsigned int ms) {
#ifdef _WIN32
    Sleep((DWORD)ms);
    return 1;
#else
    struct timespec ts;
    ts.tv_sec = (time_t)(ms / 1000U);
    ts.tv_nsec = (long)(ms % 1000U) * 1000000L;
    return nanosleep(&ts, NULL) == 0;
#endif
}

static int rducks_queue_execute_scalar_inline_on_main(rducks_runtime_entry_t *runtime,
                                                      rducks_r_scalar_meta_t *meta,
                                                      duckdb_data_chunk input, duckdb_vector output,
                                                      char *err_msg, size_t err_cap) {
    rducks_udf_request_t request;
    int ok;
    if (!runtime || !rducks_is_main_thread(runtime)) {
        snprintf(err_msg, err_cap, "Rducks inline queue-drain path must start on the recorded main R thread");
        return 0;
    }
    if (!meta) {
        snprintf(err_msg, err_cap, "Rducks inline scalar metadata is missing");
        return 0;
    }

    /* Drain until the queue is empty at this point. The removed self-shim used
     * a synthetic request as a barrier, which forced the main thread to execute
     * all pending requests ahead of that marker. A single bounded wave here can
     * leave earlier worker callbacks blocked with no later main-thread callback
     * guaranteed to drain them.
     */
    (void)rducks_queue_drain_on_main(runtime, 0);

    memset(&request, 0, sizeof(request));
    request.runtime = runtime;
    request.execute = rducks_queue_execute_scalar_on_main;
    request.meta = meta;
    request.input = input;
    request.output = output;
    request.state = RDUCKS_REQUEST_RUNNING;
    ok = rducks_queue_execute_on_main(&request, err_msg, err_cap);

    (void)rducks_queue_drain_on_main(runtime, 0);
    return ok;
}

static int rducks_queue_drain_on_main(rducks_runtime_entry_t *runtime, int max_requests) {
    int count = 0;
    if (!runtime || !runtime->queue_initialized) return 0;
    if (!rducks_is_main_thread(runtime)) return 0;
    if (max_requests <= 0) max_requests = 1000000;

    while (count < max_requests) {
        rducks_udf_request_t *request;
        char err_msg[RDUCKS_QUEUE_ERROR_SIZE];
        int ok;
        request = rducks_queue_pop_request(runtime);
        if (!request) break;
        err_msg[0] = '\0';
        ok = rducks_queue_execute_on_main(request, err_msg, sizeof(err_msg));
        rducks_queue_finish_request(runtime, request, ok, err_msg);
        count++;
    }

    rducks_queue_lock(runtime);
    runtime->queue_main_drains++;
    if (count > 0) {
        runtime->queue_main_drain_batches++;
        if ((uint64_t)count > runtime->queue_main_drain_max_batch) {
            runtime->queue_main_drain_max_batch = (uint64_t)count;
        }
    }
    rducks_queue_unlock(runtime);
    return count;
}

typedef struct rducks_queue_self_test_state {
    rducks_runtime_entry_t *runtime;
    volatile int worker_done;
    int worker_ok;
    uint64_t value;
    char error[RDUCKS_QUEUE_ERROR_SIZE];
} rducks_queue_self_test_state_t;

static int rducks_queue_self_test_execute(rducks_udf_request_t *request, char *err_msg, size_t err_cap) {
    rducks_queue_self_test_state_t *state = (rducks_queue_self_test_state_t *)request->data;
    (void)err_msg;
    (void)err_cap;
    if (!state) return 0;
    state->value++;
    return 1;
}

#ifdef _WIN32
static DWORD WINAPI rducks_queue_self_test_worker(LPVOID arg) {
#else
static void *rducks_queue_self_test_worker(void *arg) {
#endif
    rducks_queue_self_test_state_t *state = (rducks_queue_self_test_state_t *)arg;
    rducks_udf_request_t request;
    memset(&request, 0, sizeof(request));
    request.execute = rducks_queue_self_test_execute;
    request.data = state;
    state->worker_ok = rducks_queue_submit_request(state->runtime, &request,
        "Rducks queue self-test timed out waiting for the recorded main R thread",
        state->error, sizeof(state->error));
    state->worker_done = 1;
#ifdef _WIN32
    return 0;
#else
    return NULL;
#endif
}

static int rducks_queue_self_test(rducks_runtime_entry_t *runtime, uint64_t iterations,
                                  uint64_t *out_value, char *err_msg, size_t err_cap) {
    uint64_t i;
    if (!runtime || !out_value) {
        snprintf(err_msg, err_cap, "Rducks queue self-test runtime is not initialized");
        return 0;
    }
    if (!rducks_is_main_thread(runtime)) {
        snprintf(err_msg, err_cap, "Rducks queue self-test must run on the recorded main R thread");
        return 0;
    }
    *out_value = 0;
    if (iterations == 0) return 1;

    for (i = 0; i < iterations; i++) {
        rducks_queue_self_test_state_t state;
        unsigned int spins = 0;
        memset(&state, 0, sizeof(state));
        state.runtime = runtime;
#ifdef _WIN32
        HANDLE worker = CreateThread(NULL, 0, rducks_queue_self_test_worker, &state, 0, NULL);
        if (!worker) {
            snprintf(err_msg, err_cap, "failed to create Rducks queue self-test worker thread");
            return 0;
        }
#else
        pthread_t worker;
        if (pthread_create(&worker, NULL, rducks_queue_self_test_worker, &state) != 0) {
            snprintf(err_msg, err_cap, "failed to create Rducks queue self-test worker thread");
            return 0;
        }
#endif
        while (!state.worker_done && spins < 5000U) {
            (void)rducks_queue_drain_on_main(runtime, 1000);
            if (!state.worker_done) rducks_queue_sleep_ms(1);
            spins++;
        }
#ifdef _WIN32
        WaitForSingleObject(worker, INFINITE);
        CloseHandle(worker);
#else
        pthread_join(worker, NULL);
#endif
        if (!state.worker_done) {
            snprintf(err_msg, err_cap, "Rducks queue self-test worker did not finish");
            return 0;
        }
        if (!state.worker_ok) {
            rducks_queue_error_copy(err_msg, err_cap, state.error, "Rducks queue self-test worker failed");
            return 0;
        }
        *out_value += state.value;
    }
    return 1;
}
