/* Included by ../rducks_extension.c. */

#define RDUCKS_QUEUE_ERROR_SIZE 512
#define RDUCKS_QUEUE_WAIT_MS 100U
#define RDUCKS_QUEUE_TIMEOUT_TICKS 300U
#define RDUCKS_QUEUE_PENDING_TIMEOUT_MS ((uint64_t)RDUCKS_QUEUE_WAIT_MS * (uint64_t)RDUCKS_QUEUE_TIMEOUT_TICKS)
#define RDUCKS_RIPC_COALESCE_WAIT_MS 2U
#define RDUCKS_RIPC_MAIN_WAVE_MAX 64U

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
    SEXP ripc_future;
    SEXP ripc_output_schema_xptr;
    idx_t ripc_n;
    int ripc_submitted;
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

static int rducks_queue_submit_ripc_request_on_main(rducks_udf_request_t *request,
                                                    char *err_msg, size_t err_cap) {
    if (!request || !request->runtime || !request->meta) {
        snprintf(err_msg, err_cap, "Rducks queued RIPC request is missing execution state");
        return 0;
    }
    if (request->ripc_submitted) return 1;
    if (!rducks_ripc_submit_chunk_on_main(request->runtime, request->meta, request->input,
                                          &request->ripc_future, &request->ripc_output_schema_xptr,
                                          &request->ripc_n, err_msg, err_cap)) {
        rducks_ripc_release_preserved(&request->ripc_future, &request->ripc_output_schema_xptr);
        request->ripc_submitted = 0;
        return 0;
    }
    request->ripc_submitted = 1;
    return 1;
}

static int rducks_queue_collect_ripc_request_on_main(rducks_udf_request_t *request,
                                                     char *err_msg, size_t err_cap) {
    int ok;
    if (!request || !request->runtime || !request->meta || !request->ripc_submitted) {
        snprintf(err_msg, err_cap, "Rducks queued RIPC request was not submitted");
        return 0;
    }
    ok = rducks_ripc_collect_chunk_on_main(request->runtime, request->meta, &request->ripc_future,
                                          &request->ripc_output_schema_xptr, request->ripc_n,
                                          request->output, err_msg, err_cap);
    rducks_ripc_release_preserved(&request->ripc_future, &request->ripc_output_schema_xptr);
    request->ripc_submitted = 0;
    return ok;
}

static void rducks_queue_cancel_remaining_ripc_on_main(rducks_r_scalar_meta_t *meta,
                                                       rducks_udf_request_t **requests,
                                                       int *done, size_t count) {
    size_t remaining = 0;
    size_t pos = 0;
    int protect_count = 0;
    int r_err = 0;
    SEXP futures;
    SEXP result;
    if (!meta || !requests || !done || !rducks_ripc_bundle_has_cancel(meta->fun)) return;
    for (size_t i = 0; i < count; i++) {
        if (!done[i] && requests[i] && requests[i]->ripc_submitted &&
            requests[i]->ripc_future && requests[i]->ripc_future != R_NilValue) {
            remaining++;
        }
    }
    if (remaining == 0U) return;
    futures = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)remaining));
    protect_count++;
    for (size_t i = 0; i < count; i++) {
        if (!done[i] && requests[i] && requests[i]->ripc_submitted &&
            requests[i]->ripc_future && requests[i]->ripc_future != R_NilValue) {
            SET_VECTOR_ELT(futures, (R_xlen_t)pos, requests[i]->ripc_future);
            pos++;
        }
    }
    result = rducks_ripc_call_cancel_on_r_thread(meta, futures, &protect_count, &r_err);
    (void)result;
    UNPROTECT(protect_count);
}

static int rducks_queue_collect_ripc_group_any_on_main_impl(rducks_udf_request_t *head, size_t count,
                                                            char *err_msg, size_t err_cap) {
    rducks_udf_request_t *request;
    rducks_r_scalar_meta_t *meta;
    rducks_udf_request_t **requests;
    size_t *remaining_map;
    int *done;
    size_t i = 0;
    size_t remaining;
    int ok = 0;

    if (!head || count == 0U || !head->runtime || !head->meta) {
        snprintf(err_msg, err_cap, "Rducks queued RIPC collect-any group is missing state");
        return 0;
    }
    if (!rducks_is_main_thread(head->runtime)) {
        snprintf(err_msg, err_cap, "Rducks queued RIPC collect-any group reached a non-main thread");
        return 0;
    }
    meta = head->meta;
    requests = (rducks_udf_request_t **)R_alloc(count, sizeof(*requests));
    remaining_map = (size_t *)R_alloc(count, sizeof(*remaining_map));
    done = (int *)R_alloc(count, sizeof(*done));
    memset(requests, 0, count * sizeof(*requests));
    memset(done, 0, count * sizeof(*done));

    for (request = head; request && i < count; request = request->next, i++) {
        if (!request->runtime || request->meta != meta || !request->ripc_submitted ||
            !request->ripc_future || request->ripc_future == R_NilValue ||
            !request->ripc_output_schema_xptr || request->ripc_output_schema_xptr == R_NilValue) {
            snprintf(err_msg, err_cap, "Rducks queued RIPC collect-any group contains an invalid request");
            goto done_any;
        }
        requests[i] = request;
    }
    if (i != count) {
        snprintf(err_msg, err_cap, "Rducks queued RIPC collect-any group length mismatch");
        goto done_any;
    }

    remaining = count;
    while (remaining > 0U) {
        int protect_count = 0;
        int r_err = 0;
        SEXP futures = R_NilValue;
        SEXP schemas = R_NilValue;
        SEXP ns = R_NilValue;
        SEXP results = R_NilValue;
        SEXP indices = R_NilValue;
        SEXP payloads = R_NilValue;
        R_xlen_t ready_count = 0;
        size_t pos = 0;

        futures = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)remaining));
        protect_count++;
        schemas = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)remaining));
        protect_count++;
        ns = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t)remaining));
        protect_count++;

        for (i = 0; i < count; i++) {
            if (done[i]) continue;
            remaining_map[pos] = i;
            SET_VECTOR_ELT(futures, (R_xlen_t)pos, requests[i]->ripc_future);
            SET_VECTOR_ELT(schemas, (R_xlen_t)pos, requests[i]->ripc_output_schema_xptr);
            REAL(ns)[pos] = (double)requests[i]->ripc_n;
            pos++;
        }
        if (pos != remaining) {
            UNPROTECT(protect_count);
            snprintf(err_msg, err_cap, "Rducks queued RIPC collect-any remaining-count mismatch");
            goto done_any;
        }

        results = rducks_ripc_call_collect_any_on_r_thread(meta, futures, schemas, ns, remaining,
                                                           &protect_count, &r_err);
        if (r_err) {
            UNPROTECT(protect_count);
            snprintf(err_msg, err_cap, "Rducks Future Arrow IPC collect-any failed");
            goto done_any;
        }
        if (rducks_r_scalar_result_is_error(results, err_msg, err_cap)) {
            UNPROTECT(protect_count);
            goto done_any;
        }
        if (TYPEOF(results) != VECSXP) {
            UNPROTECT(protect_count);
            snprintf(err_msg, err_cap, "Rducks Future Arrow IPC collect-any returned a non-list result");
            goto done_any;
        }
        indices = rducks_named_list_get(results, "indices");
        payloads = rducks_named_list_get(results, "payloads");
        if (payloads == R_NilValue) payloads = rducks_named_list_get(results, "arrays");
        if (indices == R_NilValue && XLENGTH(results) >= 1) indices = VECTOR_ELT(results, 0);
        if (payloads == R_NilValue && XLENGTH(results) >= 2) payloads = VECTOR_ELT(results, 1);
        if ((TYPEOF(indices) != INTSXP && TYPEOF(indices) != REALSXP) || TYPEOF(payloads) != VECSXP) {
            UNPROTECT(protect_count);
            snprintf(err_msg, err_cap, "Rducks Future Arrow IPC collect-any returned invalid indices/payloads");
            goto done_any;
        }
        ready_count = XLENGTH(indices);
        if (XLENGTH(payloads) != ready_count) {
            UNPROTECT(protect_count);
            snprintf(err_msg, err_cap, "Rducks Future Arrow IPC collect-any result length mismatch");
            goto done_any;
        }
        if (ready_count == 0) {
            UNPROTECT(protect_count);
            (void)rducks_queue_sleep_ms(1U);
            continue;
        }
        rducks_udf_record_ripc_batch(meta, (size_t)ready_count);
        rducks_udf_record_ripc_collect_ready(meta, (size_t)ready_count);

        for (R_xlen_t j = 0; j < ready_count; j++) {
            double raw_index = TYPEOF(indices) == INTSXP ? (double)INTEGER(indices)[j] : REAL(indices)[j];
            size_t remaining_index;
            size_t request_index;
            rducks_udf_request_t *ready_request;
            if (!R_FINITE(raw_index) || floor(raw_index) != raw_index ||
                raw_index < 1.0 || raw_index > (double)remaining) {
                UNPROTECT(protect_count);
                snprintf(err_msg, err_cap, "Rducks Future Arrow IPC collect-any returned an invalid index");
                goto done_any;
            }
            remaining_index = (size_t)(raw_index - 1.0);
            request_index = remaining_map[remaining_index];
            if (request_index >= count || done[request_index]) {
                UNPROTECT(protect_count);
                snprintf(err_msg, err_cap, "Rducks Future Arrow IPC collect-any returned a duplicate index");
                goto done_any;
            }
            ready_request = requests[request_index];
            if (!rducks_r_scalar_emit_arrow_result(ready_request->runtime, ready_request->meta,
                                                  VECTOR_ELT(payloads, j), ready_request->ripc_output_schema_xptr,
                                                  ready_request->ripc_n, ready_request->output,
                                                  err_msg, err_cap)) {
                UNPROTECT(protect_count);
                goto done_any;
            }
            done[request_index] = 1;
            remaining--;
            rducks_udf_record_ripc_inflight_done(meta, 1U);
            rducks_ripc_release_preserved(&ready_request->ripc_future, &ready_request->ripc_output_schema_xptr);
            ready_request->ripc_submitted = 0;
        }
        UNPROTECT(protect_count);
    }
    ok = 1;

done_any:
    if (!ok) {
        rducks_queue_cancel_remaining_ripc_on_main(meta, requests, done, count);
        for (i = 0; i < count; i++) {
            if (!done[i] && requests[i] && requests[i]->ripc_submitted) {
                rducks_udf_record_ripc_inflight_done(requests[i]->meta, 1U);
                rducks_ripc_release_preserved(&requests[i]->ripc_future, &requests[i]->ripc_output_schema_xptr);
                requests[i]->ripc_submitted = 0;
            }
        }
    }
    return ok;
}

static int rducks_queue_collect_ripc_group_on_main_impl(rducks_udf_request_t *head, size_t count,
                                                        char *err_msg, size_t err_cap) {
    rducks_udf_request_t *request;
    rducks_r_scalar_meta_t *meta;
    int protect_count = 0;
    int r_err = 0;
    SEXP futures = R_NilValue;
    SEXP schemas = R_NilValue;
    SEXP ns = R_NilValue;
    SEXP results = R_NilValue;
    size_t i = 0;
    int ok = 0;

    if (!head || count == 0U || !head->runtime || !head->meta) {
        snprintf(err_msg, err_cap, "Rducks queued RIPC collect group is missing state");
        return 0;
    }
    if (!rducks_is_main_thread(head->runtime)) {
        snprintf(err_msg, err_cap, "Rducks queued RIPC collect group reached a non-main thread");
        return 0;
    }
    meta = head->meta;
    if (rducks_ripc_bundle_has_collect_any(meta->fun)) {
        return rducks_queue_collect_ripc_group_any_on_main_impl(head, count, err_msg, err_cap);
    }
    rducks_udf_record_ripc_batch(meta, count);

    futures = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)count));
    protect_count++;
    schemas = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)count));
    protect_count++;
    ns = PROTECT(Rf_allocVector(REALSXP, (R_xlen_t)count));
    protect_count++;

    for (request = head; request && i < count; request = request->next, i++) {
        if (!request->runtime || request->meta != meta || !request->ripc_submitted ||
            !request->ripc_future || request->ripc_future == R_NilValue ||
            !request->ripc_output_schema_xptr || request->ripc_output_schema_xptr == R_NilValue) {
            snprintf(err_msg, err_cap, "Rducks queued RIPC collect group contains an invalid request");
            goto done;
        }
        SET_VECTOR_ELT(futures, (R_xlen_t)i, request->ripc_future);
        SET_VECTOR_ELT(schemas, (R_xlen_t)i, request->ripc_output_schema_xptr);
        REAL(ns)[i] = (double)request->ripc_n;
    }
    if (i != count) {
        snprintf(err_msg, err_cap, "Rducks queued RIPC collect group length mismatch");
        goto done;
    }

    results = rducks_ripc_call_collect_many_on_r_thread(meta, futures, schemas, ns, &protect_count, &r_err);
    if (r_err) {
        snprintf(err_msg, err_cap, "Rducks Future Arrow IPC collect-many failed");
        goto done;
    }
    if (rducks_r_scalar_result_is_error(results, err_msg, err_cap)) goto done;
    if (TYPEOF(results) != VECSXP || XLENGTH(results) != (R_xlen_t)count) {
        snprintf(err_msg, err_cap, "Rducks Future Arrow IPC collect-many returned %lld results, expected %llu",
                 (long long)(TYPEOF(results) == VECSXP ? XLENGTH(results) : -1),
                 (unsigned long long)count);
        goto done;
    }
    rducks_udf_record_ripc_collect_ready(meta, count);

    i = 0;
    for (request = head; request && i < count; request = request->next, i++) {
        if (!rducks_r_scalar_emit_arrow_result(request->runtime, request->meta, VECTOR_ELT(results, (R_xlen_t)i),
                                              request->ripc_output_schema_xptr, request->ripc_n,
                                              request->output, err_msg, err_cap)) {
            goto done;
        }
    }
    ok = 1;

done:
    rducks_udf_record_ripc_inflight_done(meta, count);
    i = 0;
    for (request = head; request && i < count; request = request->next, i++) {
        rducks_ripc_release_preserved(&request->ripc_future, &request->ripc_output_schema_xptr);
        request->ripc_submitted = 0;
    }
    UNPROTECT(protect_count);
    return ok;
}

typedef struct rducks_ripc_collect_group_context {
    rducks_udf_request_t *head;
    size_t count;
    char *err_msg;
    size_t err_cap;
    int ok;
} rducks_ripc_collect_group_context_t;

static void rducks_ripc_collect_group_release_requests(rducks_udf_request_t *head, size_t count,
                                                       int record_inflight_done) {
    rducks_udf_request_t *request;
    size_t i = 0;
    for (request = head; request && i < count; request = request->next, i++) {
        if (record_inflight_done && request->ripc_submitted && request->meta) {
            rducks_udf_record_ripc_inflight_done(request->meta, 1U);
        }
        rducks_ripc_release_preserved(&request->ripc_future, &request->ripc_output_schema_xptr);
        request->ripc_submitted = 0;
    }
}

static SEXP rducks_ripc_collect_group_unwind_body(void *data) {
    rducks_ripc_collect_group_context_t *ctx = (rducks_ripc_collect_group_context_t *)data;
    ctx->ok = rducks_queue_collect_ripc_group_on_main_impl(ctx->head, ctx->count,
                                                           ctx->err_msg, ctx->err_cap);
    return R_NilValue;
}

static void rducks_ripc_collect_group_unwind_cleanup(void *data, Rboolean jump) {
    rducks_ripc_collect_group_context_t *ctx = (rducks_ripc_collect_group_context_t *)data;
    if (jump) {
        ctx->ok = 0;
        rducks_ripc_collect_group_release_requests(ctx->head, ctx->count, 1);
        rducks_ripc_set_default_error(ctx->err_msg, ctx->err_cap,
                                       "Rducks Future Arrow IPC collect-many failed");
    }
}

static SEXP rducks_ripc_collect_group_try_body(void *data) {
    return R_UnwindProtect(rducks_ripc_collect_group_unwind_body, data,
                           rducks_ripc_collect_group_unwind_cleanup, data,
                           NULL);
}

static SEXP rducks_ripc_collect_group_error_handler(SEXP condition, void *data) {
    (void)condition;
    rducks_ripc_collect_group_context_t *ctx = (rducks_ripc_collect_group_context_t *)data;
    ctx->ok = 0;
    rducks_ripc_set_default_error(ctx->err_msg, ctx->err_cap,
                                   "Rducks Future Arrow IPC collect-many failed");
    return R_NilValue;
}

static int rducks_queue_collect_ripc_group_on_main(rducks_udf_request_t *head, size_t count,
                                                   char *err_msg, size_t err_cap) {
    rducks_ripc_collect_group_context_t ctx;
    memset(&ctx, 0, sizeof(ctx));
    if (err_msg && err_cap > 0U) err_msg[0] = '\0';
    ctx.head = head;
    ctx.count = count;
    ctx.err_msg = err_msg;
    ctx.err_cap = err_cap;
    (void)R_tryCatchError(rducks_ripc_collect_group_try_body, &ctx,
                          rducks_ripc_collect_group_error_handler, &ctx);
    return ctx.ok;
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

static int rducks_queue_request_is_ripc(rducks_udf_request_t *request) {
    return request && request->meta && request->meta->eval_mode == RDUCKS_EVAL_RIPC;
}

static void rducks_queue_record_local_start(rducks_runtime_entry_t *runtime) {
    if (!runtime) return;
    rducks_queue_lock(runtime);
    runtime->queue_submitted++;
    runtime->queue_running_current++;
    if (runtime->queue_running_current > runtime->queue_running_max) {
        runtime->queue_running_max = runtime->queue_running_current;
    }
    rducks_queue_unlock(runtime);
}

static void rducks_queue_record_local_finish(rducks_runtime_entry_t *runtime) {
    if (!runtime) return;
    rducks_queue_lock(runtime);
    runtime->queue_executed++;
    if (runtime->queue_running_current > 0) runtime->queue_running_current--;
    rducks_queue_unlock(runtime);
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

static void rducks_queue_append_local(rducks_udf_request_t **head, rducks_udf_request_t **tail,
                                      rducks_udf_request_t *request) {
    if (!request) return;
    request->next = NULL;
    if (*tail) {
        (*tail)->next = request;
    } else {
        *head = request;
    }
    *tail = request;
}

static rducks_udf_request_t *rducks_queue_pop_request(rducks_runtime_entry_t *runtime) {
    rducks_udf_request_t *request;
    rducks_queue_lock(runtime);
    request = rducks_queue_pop_locked(runtime);
    rducks_queue_unlock(runtime);
    return request;
}

static rducks_udf_request_t *rducks_queue_pop_request_after_wait(rducks_runtime_entry_t *runtime,
                                                                 unsigned int wait_ms) {
    rducks_udf_request_t *request;
    rducks_queue_lock(runtime);
    request = rducks_queue_pop_locked(runtime);
    if (!request && wait_ms > 0U) {
        (void)rducks_queue_wait_timed(runtime, wait_ms);
        request = rducks_queue_pop_locked(runtime);
    }
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
    request.execute = rducks_rc_owned_result_queue_supported(meta) ?
        rducks_queue_execute_rc_scalar_to_payload_on_main :
        rducks_queue_execute_scalar_on_main;
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

static int rducks_queue_collect_ripc_groups_on_main(rducks_runtime_entry_t *runtime,
                                                    rducks_udf_request_t *ripc_head,
                                                    rducks_udf_request_t *local_request,
                                                    char *err_msg, size_t err_cap) {
    int all_ok = 1;
    int local_ok = 0;
    if (!runtime || !ripc_head) {
        snprintf(err_msg, err_cap, "Rducks queued RIPC collect groups are missing state");
        return 0;
    }

    while (ripc_head) {
        rducks_udf_request_t *group_head = ripc_head;
        rducks_udf_request_t *group_tail = ripc_head;
        rducks_udf_request_t *next = ripc_head->next;
        rducks_r_scalar_meta_t *meta = ripc_head->meta;
        char group_err[RDUCKS_QUEUE_ERROR_SIZE];
        size_t group_count = 1U;
        int group_has_local = (group_head == local_request);
        int ok;

        while (next && next->meta == meta) {
            group_tail = next;
            if (next == local_request) group_has_local = 1;
            next = next->next;
            group_count++;
        }
        group_tail->next = NULL;
        rducks_udf_record_ripc_submit_wave(meta, group_count);
        group_err[0] = '\0';
        ok = rducks_queue_collect_ripc_group_on_main(group_head, group_count, group_err, sizeof(group_err));
        if (group_has_local) local_ok = ok;
        if (!ok) {
            all_ok = 0;
            if (err_msg && err_cap > 0U && err_msg[0] == '\0') {
                rducks_queue_error_copy(err_msg, err_cap, group_err, "Rducks queued Future Arrow IPC collect group failed");
            }
        }

        while (group_head) {
            rducks_udf_request_t *finished = group_head;
            group_head = group_head->next;
            finished->next = NULL;
            if (finished != local_request) {
                rducks_queue_finish_request(runtime, finished, ok, group_err);
            }
        }
        ripc_head = next;
    }

    if (local_request && !local_ok) return 0;
    return all_ok;
}

static int rducks_queue_submit_ripc_cooperative_on_main(rducks_runtime_entry_t *runtime,
                                                        rducks_r_scalar_meta_t *meta,
                                                        duckdb_data_chunk input, duckdb_vector output,
                                                        char *err_msg, size_t err_cap) {
    rducks_udf_request_t local_request;
    rducks_udf_request_t *ripc_head = NULL;
    rducks_udf_request_t *ripc_tail = NULL;
    size_t submitted = 0U;

    if (!runtime || !meta || meta->eval_mode != RDUCKS_EVAL_RIPC) {
        snprintf(err_msg, err_cap, "Rducks cooperative RIPC scheduler is missing state");
        return 0;
    }
    if (!rducks_is_main_thread(runtime)) {
        snprintf(err_msg, err_cap, "Rducks cooperative RIPC scheduler must run on the recorded main R thread");
        return 0;
    }

    memset(&local_request, 0, sizeof(local_request));
    local_request.runtime = runtime;
    local_request.meta = meta;
    local_request.input = input;
    local_request.output = output;
    local_request.state = RDUCKS_REQUEST_RUNNING;
    local_request.error[0] = '\0';

    rducks_queue_record_local_start(runtime);
    if (!rducks_queue_submit_ripc_request_on_main(&local_request, err_msg, err_cap)) {
        rducks_ripc_release_preserved(&local_request.ripc_future, &local_request.ripc_output_schema_xptr);
        rducks_queue_record_local_finish(runtime);
        return 0;
    }
    rducks_queue_append_local(&ripc_head, &ripc_tail, &local_request);
    submitted++;

    while (submitted < RDUCKS_RIPC_MAIN_WAVE_MAX) {
        rducks_udf_request_t *request;
        char request_err[RDUCKS_QUEUE_ERROR_SIZE];
        int ok;

        request = rducks_queue_pop_request_after_wait(runtime, RDUCKS_RIPC_COALESCE_WAIT_MS);
        if (!request) break;
        request_err[0] = '\0';

        if (rducks_queue_request_is_ripc(request)) {
            ok = rducks_queue_submit_ripc_request_on_main(request, request_err, sizeof(request_err));
            if (ok) {
                rducks_queue_append_local(&ripc_head, &ripc_tail, request);
            } else {
                rducks_queue_finish_request(runtime, request, 0, request_err);
            }
        } else {
            ok = rducks_queue_execute_on_main(request, request_err, sizeof(request_err));
            rducks_queue_finish_request(runtime, request, ok, request_err);
        }
        submitted++;
    }

    err_msg[0] = '\0';
    {
        int ok = rducks_queue_collect_ripc_groups_on_main(runtime, ripc_head, &local_request, err_msg, err_cap);
        rducks_queue_record_local_finish(runtime);
        return ok;
    }
}

static int rducks_queue_drain_on_main(rducks_runtime_entry_t *runtime, int max_requests) {
    int count = 0;
    if (!runtime || !runtime->queue_initialized) return 0;
    if (!rducks_is_main_thread(runtime)) return 0;
    if (max_requests <= 0) max_requests = 1000000;

    while (count < max_requests) {
        rducks_udf_request_t *ripc_head = NULL;
        rducks_udf_request_t *ripc_tail = NULL;
        int popped_this_round = 0;

        while (count < max_requests) {
            rducks_udf_request_t *request;
            char err_msg[RDUCKS_QUEUE_ERROR_SIZE];
            int ok;

            request = ripc_head ?
                rducks_queue_pop_request_after_wait(runtime, RDUCKS_RIPC_COALESCE_WAIT_MS) :
                rducks_queue_pop_request(runtime);
            if (!request) break;
            popped_this_round = 1;

            err_msg[0] = '\0';
            if (rducks_queue_request_is_ripc(request)) {
                ok = rducks_queue_submit_ripc_request_on_main(request, err_msg, sizeof(err_msg));
                if (ok) {
                    rducks_queue_append_local(&ripc_head, &ripc_tail, request);
                } else {
                    rducks_queue_finish_request(runtime, request, 0, err_msg);
                }
            } else {
                ok = rducks_queue_execute_on_main(request, err_msg, sizeof(err_msg));
                rducks_queue_finish_request(runtime, request, ok, err_msg);
            }
            count++;
        }

        while (ripc_head) {
            rducks_udf_request_t *group_head = ripc_head;
            rducks_udf_request_t *group_tail = ripc_head;
            rducks_udf_request_t *next = ripc_head->next;
            rducks_r_scalar_meta_t *meta = ripc_head->meta;
            char err_msg[RDUCKS_QUEUE_ERROR_SIZE];
            size_t group_count = 1U;
            int ok;

            while (next && next->meta == meta) {
                group_tail = next;
                next = next->next;
                group_count++;
            }
            group_tail->next = NULL;
            rducks_udf_record_ripc_submit_wave(meta, group_count);
            err_msg[0] = '\0';
            ok = rducks_queue_collect_ripc_group_on_main(group_head, group_count, err_msg, sizeof(err_msg));
            while (group_head) {
                rducks_udf_request_t *finished = group_head;
                group_head = group_head->next;
                finished->next = NULL;
                rducks_queue_finish_request(runtime, finished, ok, err_msg);
            }
            ripc_head = next;
        }

        if (!popped_this_round) break;
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
