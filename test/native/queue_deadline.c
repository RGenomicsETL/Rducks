/* Queue synchronization fixture. Production functions are compiled from the
 * generated header, not copied into this fixture. See queue_deadline.py. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define RDUCKS_QUEUE_WAIT_MS 100U
#define RDUCKS_QUEUE_TIMEOUT_TICKS 300U
#define RDUCKS_QUEUE_PENDING_TIMEOUT_MS 30000U
#define RDUCKS_REQUEST_PENDING 0
#define RDUCKS_REQUEST_RUNNING 1
#define RDUCKS_REQUEST_DONE 2
#define RDUCKS_REQUEST_CANCELLED 3

typedef struct request rducks_udf_request_t;
typedef struct runtime {
    pthread_mutex_t queue_lock;
    pthread_cond_t queue_cond;
    int queue_initialized;
    atomic_uint_fast64_t queue_cancel_generation;
    rducks_udf_request_t *queue_head, *queue_tail;
    uint64_t queue_submitted, queue_executed, queue_timeouts;
    uint64_t queue_pending_current, queue_pending_max, queue_running_current;
} rducks_runtime_entry_t;

struct request {
    rducks_udf_request_t *next;
    rducks_runtime_entry_t *runtime;
    void (*execute)(void);
    atomic_int *meta;
    int state, cancel_generation_set, ok;
    uint64_t cancel_generation;
    char error[512];
};

static atomic_uint_fast64_t clock_advance_us;
static int test_clock_gettime(clockid_t clock_id, struct timespec *ts) {
    int result = clock_gettime(clock_id, ts);
    if (!result && clock_id == CLOCK_MONOTONIC) {
        uint64_t ns = (uint64_t)ts->tv_nsec + atomic_load(&clock_advance_us) * 1000U;
        ts->tv_sec += (time_t)(ns / 1000000000U);
        ts->tv_nsec = (long)(ns % 1000000000U);
    }
    return result;
}
#define clock_gettime test_clock_gettime

static void rducks_format_error_message(char *out, size_t cap, const char *format, ...) {
    va_list args;
    va_start(args, format);
    vsnprintf(out, cap, format, args);
    va_end(args);
}
static void rducks_udf_record_queue_pending_add(atomic_int *meta) { atomic_fetch_add(meta, 1); }
static void rducks_udf_record_queue_pending_done(atomic_int *meta) { atomic_fetch_sub(meta, 1); }

#include "queue_under_test.h"

typedef struct test_state {
    rducks_runtime_entry_t runtime;
    rducks_udf_request_t request;
    atomic_int pending, done;
    int ok;
    char error[512];
} test_state;

static void no_execute(void) {}
static void *submit(void *arg) {
    test_state *state = arg;
    state->ok = rducks_queue_submit_request(&state->runtime, &state->request, NULL,
                                           state->error, sizeof(state->error));
    atomic_store(&state->done, 1);
    return NULL;
}

static void claim(test_state *state) {
    rducks_queue_lock(&state->runtime);
    state->runtime.queue_head = state->runtime.queue_tail = NULL;
    state->runtime.queue_pending_current--;
    state->runtime.queue_running_current++;
    state->request.state = RDUCKS_REQUEST_RUNNING;
    rducks_queue_unlock(&state->runtime);
}

enum scenario { NOTIFICATION_STORM, ELAPSED_DEADLINE, PENDING_CANCEL, RUNNING_CANCEL };

static int check(enum scenario scenario, const char *name) {
    test_state state = {0};
    pthread_t worker;
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 1000000};
    int premature = 0;
    atomic_store(&clock_advance_us, 0);
    uint64_t started_us = rducks_queue_now_us();
    pthread_mutex_init(&state.runtime.queue_lock, NULL);
    pthread_cond_init(&state.runtime.queue_cond, NULL);
    state.runtime.queue_initialized = 1;
    state.request.execute = no_execute;
    state.request.meta = &state.pending;
    if (pthread_create(&worker, NULL, submit, &state) != 0) return 0;
    for (;;) {
        int ready;
        rducks_queue_lock(&state.runtime);
        ready = state.runtime.queue_pending_current != 0;
        rducks_queue_unlock(&state.runtime);
        if (ready || atomic_load(&state.done)) break;
        sched_yield();
    }
    if (scenario == RUNNING_CANCEL) claim(&state);
    if (scenario == ELAPSED_DEADLINE || scenario == RUNNING_CANCEL) {
        atomic_store(&clock_advance_us, (uint64_t)RDUCKS_QUEUE_PENDING_TIMEOUT_MS * 1000U + 1U);
    }
    if (scenario == PENDING_CANCEL || scenario == RUNNING_CANCEL) {
        atomic_fetch_add(&state.runtime.queue_cancel_generation, 1U);
    }
    int notifications = scenario == NOTIFICATION_STORM ? 600 : 30;
    for (int i = 0; i < notifications; i++) {
        rducks_queue_lock(&state.runtime);
        rducks_queue_signal_all(&state.runtime);
        rducks_queue_unlock(&state.runtime);
        nanosleep(&delay, NULL);
    }
    if (scenario == NOTIFICATION_STORM || scenario == RUNNING_CANCEL) {
        premature = atomic_load(&state.done);
        if (!premature) {
            if (scenario == NOTIFICATION_STORM) claim(&state);
            rducks_queue_finish_request(&state.runtime, &state.request, 1, NULL);
        }
    }
    pthread_join(worker, NULL);
    int expect_ok = scenario == NOTIFICATION_STORM || scenario == RUNNING_CANCEL;
    int pass = !premature && state.ok == expect_ok &&
        state.runtime.queue_timeouts == (uint64_t)(scenario == ELAPSED_DEADLINE) &&
        atomic_load(&state.pending) == 0 && state.runtime.queue_pending_current == 0 &&
        state.runtime.queue_running_current == 0 && !state.runtime.queue_head && !state.runtime.queue_tail;
    if (scenario == ELAPSED_DEADLINE) pass = pass && strstr(state.error, "timed out") != NULL;
    if (scenario == PENDING_CANCEL) pass = pass && strstr(state.error, "interrupted") != NULL;
    if (scenario == NOTIFICATION_STORM) pass = pass &&
        rducks_queue_now_us() - started_us < (uint64_t)RDUCKS_QUEUE_PENDING_TIMEOUT_MS * 1000U;
    printf("%s: %s\n", name, pass ? "PASS" : "FAIL");
    if (!pass) fprintf(stderr, "premature=%d ok=%d timeouts=%llu error=%s\n",
        premature, state.ok, (unsigned long long)state.runtime.queue_timeouts, state.error);
    pthread_cond_destroy(&state.runtime.queue_cond);
    pthread_mutex_destroy(&state.runtime.queue_lock);
    return pass;
}

int main(int argc, char **argv) {
    int ok = check(NOTIFICATION_STORM, "600 notifications do not exhaust the elapsed deadline");
    if (argc > 1 && strcmp(argv[1], "--storm-only") == 0) return ok ? 0 : 1;
    ok &= check(ELAPSED_DEADLINE, "elapsed deadline removes a pending request");
    ok &= check(PENDING_CANCEL, "cancellation removes a pending request");
    ok &= check(RUNNING_CANCEL, "running request survives cancellation and deadline until DONE");
    return ok ? 0 : 1;
}
