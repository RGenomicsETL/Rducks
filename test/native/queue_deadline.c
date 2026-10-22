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
typedef struct query_owner {
    atomic_int stopping;
    atomic_uint *connection;
} rducks_query_owner_t;
typedef struct runtime {
    pthread_mutex_t queue_lock;
    pthread_cond_t queue_cond;
    int queue_initialized;
    atomic_uint_fast64_t queue_cancel_generation;
    rducks_udf_request_t *queue_head, *queue_tail;
    uint64_t queue_submitted, queue_executed, queue_timeouts;
    uint64_t queue_pending_current, queue_pending_max, queue_running_current, queue_running_max;
} rducks_runtime_entry_t;

struct request {
    rducks_udf_request_t *next;
    rducks_runtime_entry_t *runtime;
    rducks_query_owner_t *owner;
    void (*execute)(void);
    atomic_int *meta;
    int state, cancel_generation_set, ok, allow_non_main_drain;
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
#ifdef RDUCKS_TEST_MANAGED_QUEUE
static void duckdb_interrupt(atomic_uint *connection) { atomic_fetch_add(connection, 1U); }
#endif

#include "queue_under_test.h"

typedef struct test_state {
    rducks_runtime_entry_t runtime;
    rducks_runtime_entry_t *shared_runtime;
    rducks_udf_request_t request;
    atomic_int pending, done;
    int ok;
    char error[512];
} test_state;

static void no_execute(void) {}
static void *submit(void *arg) {
    test_state *state = arg;
    /* The production queue borrows this worker's actual stack storage. A
     * RUNNING request must not let submit return until finish publishes DONE. */
    rducks_udf_request_t request = state->request;
    state->ok = rducks_queue_submit_request(state->shared_runtime ? state->shared_runtime : &state->runtime,
                                           &request, NULL,
                                           state->error, sizeof(state->error));
    atomic_store(&state->done, 1);
    return NULL;
}

static rducks_udf_request_t *claim(test_state *state) {
#ifdef RDUCKS_TEST_MANAGED_QUEUE
    if (state->request.owner) return rducks_queue_pop_owner_request(&state->runtime, state->request.owner);
#endif
    return rducks_queue_pop_request(&state->runtime, 0);
}

static void initialize_runtime(rducks_runtime_entry_t *runtime) {
    pthread_mutex_init(&runtime->queue_lock, NULL);
    pthread_cond_init(&runtime->queue_cond, NULL);
    runtime->queue_initialized = 1;
}

static void wait_pending(rducks_runtime_entry_t *runtime, uint64_t count, atomic_int *done) {
    for (;;) {
        int ready;
        rducks_queue_lock(runtime);
        ready = runtime->queue_pending_current == count;
        rducks_queue_unlock(runtime);
        if (ready || atomic_load(done)) break;
        sched_yield();
    }
}

static int clean_runtime(rducks_runtime_entry_t *runtime) {
    int clean = runtime->queue_pending_current == 0 && runtime->queue_running_current == 0 &&
        !runtime->queue_head && !runtime->queue_tail;
    pthread_cond_destroy(&runtime->queue_cond);
    pthread_mutex_destroy(&runtime->queue_lock);
    return clean;
}

enum scenario {
    NOTIFICATION_STORM, ELAPSED_DEADLINE, PENDING_CANCEL, RUNNING_CANCEL,
    MANAGED_PAUSE, MANAGED_STOP, MANAGED_RUNNING_STOP
};

static int check(enum scenario scenario, const char *name) {
    test_state state = {0};
    pthread_t worker;
    rducks_udf_request_t *claimed = NULL;
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 1000000};
    int premature = 0;
    int managed = scenario >= MANAGED_PAUSE;
    int holds_running = scenario == RUNNING_CANCEL || scenario == MANAGED_RUNNING_STOP;
    int expect_ok = scenario == NOTIFICATION_STORM || scenario == MANAGED_PAUSE || holds_running;
#ifdef RDUCKS_TEST_MANAGED_QUEUE
    atomic_uint interrupts = 0U;
    rducks_query_owner_t owner = {.stopping = 0, .connection = &interrupts};
    if (managed) state.request.owner = &owner;
#else
    (void)managed;
#endif
    atomic_store(&clock_advance_us, 0);
    uint64_t started_us = rducks_queue_now_us();
    initialize_runtime(&state.runtime);
    state.request.execute = no_execute;
    state.request.meta = &state.pending;
    if (pthread_create(&worker, NULL, submit, &state) != 0) return 0;
    wait_pending(&state.runtime, 1U, &state.done);
    if (holds_running) claimed = claim(&state);
    if (scenario == ELAPSED_DEADLINE || holds_running || scenario == MANAGED_PAUSE) {
        atomic_store(&clock_advance_us, (uint64_t)RDUCKS_QUEUE_PENDING_TIMEOUT_MS * 1000U + 1U);
    }
    if (scenario == PENDING_CANCEL || scenario == RUNNING_CANCEL || scenario == MANAGED_PAUSE) {
        atomic_fetch_add(&state.runtime.queue_cancel_generation, 1U);
    }
#ifdef RDUCKS_TEST_MANAGED_QUEUE
    if (scenario == MANAGED_STOP || scenario == MANAGED_RUNNING_STOP) {
        rducks_queue_stop_owner(&state.runtime, &owner);
    }
#endif
    int notifications = scenario == NOTIFICATION_STORM ? 600 : 30;
    for (int i = 0; i < notifications; i++) {
        rducks_queue_lock(&state.runtime);
        rducks_queue_signal_all(&state.runtime);
        rducks_queue_unlock(&state.runtime);
        nanosleep(&delay, NULL);
    }
    if (expect_ok) {
        premature = atomic_load(&state.done);
        if (!premature) {
            if (!claimed) claimed = claim(&state);
            if (claimed) rducks_queue_finish_request(&state.runtime, claimed, 1, NULL);
        }
    }
    pthread_join(worker, NULL);
    int pass = !premature && state.ok == expect_ok &&
        state.runtime.queue_timeouts == (uint64_t)(scenario == ELAPSED_DEADLINE) &&
        atomic_load(&state.pending) == 0 && state.runtime.queue_pending_current == 0 &&
        state.runtime.queue_running_current == 0 && !state.runtime.queue_head && !state.runtime.queue_tail;
    if (scenario == ELAPSED_DEADLINE) pass = pass && strstr(state.error, "timed out") != NULL;
    if (scenario == PENDING_CANCEL || scenario == MANAGED_STOP) {
        pass = pass && strstr(state.error, "interrupted") != NULL;
    }
    if (scenario == NOTIFICATION_STORM) pass = pass &&
        rducks_queue_now_us() - started_us < (uint64_t)RDUCKS_QUEUE_PENDING_TIMEOUT_MS * 1000U;
#ifdef RDUCKS_TEST_MANAGED_QUEUE
    if (scenario == MANAGED_STOP) {
        /* Once stopped, this owner cannot publish another borrowed request. */
        uint64_t submitted = state.runtime.queue_submitted;
        int accepted = rducks_queue_submit_request(&state.runtime, &state.request, NULL,
                                                   state.error, sizeof(state.error));
        pass = pass && !accepted && state.runtime.queue_submitted == submitted &&
            atomic_load(&state.pending) == 0 && strstr(state.error, "cancelled") != NULL;
    }
    if (scenario == MANAGED_STOP || scenario == MANAGED_RUNNING_STOP) {
        pass = pass && atomic_load(&interrupts) == 1U;
    }
#endif
    pass &= clean_runtime(&state.runtime);
    printf("%s: %s\n", name, pass ? "PASS" : "FAIL");
    if (!pass) fprintf(stderr, "premature=%d ok=%d timeouts=%llu error=%s\n",
        premature, state.ok, (unsigned long long)state.runtime.queue_timeouts, state.error);
    return pass;
}

#ifdef RDUCKS_TEST_MANAGED_QUEUE
static int check_owner_filter(void) {
    rducks_runtime_entry_t runtime = {0};
    test_state states[4] = {0};
    pthread_t workers[4];
    rducks_udf_request_t *claimed[4] = {0};
    atomic_uint interrupts = 0U;
    rducks_query_owner_t owners[2] = {
        {.stopping = 0, .connection = &interrupts},
        {.stopping = 0, .connection = &interrupts}
    };
    int pass = 1;
    atomic_store(&clock_advance_us, 0);
    initialize_runtime(&runtime);
    /* Publish A, B, legacy, A in a known order. The production pop operations
     * must select their own requests even when another owner is at the head. */
    for (size_t i = 0; i < 4; i++) {
        states[i].shared_runtime = &runtime;
        states[i].request.owner = i == 2 ? NULL : &owners[i == 1];
        states[i].request.execute = no_execute;
        states[i].request.meta = &states[i].pending;
        if (pthread_create(&workers[i], NULL, submit, &states[i]) != 0) return 0;
        wait_pending(&runtime, i + 1U, &states[i].done);
    }
    claimed[2] = rducks_queue_pop_request(&runtime, 0);
    pass &= claimed[2] && claimed[2]->meta == &states[2].pending;
    pass &= rducks_queue_pop_request(&runtime, 0) == NULL;
    claimed[0] = rducks_queue_pop_owner_request(&runtime, &owners[0]);
    claimed[3] = rducks_queue_pop_owner_request(&runtime, &owners[0]);
    pass &= claimed[0] && claimed[0]->meta == &states[0].pending;
    pass &= claimed[3] && claimed[3]->meta == &states[3].pending;
    pass &= rducks_queue_pop_owner_request(&runtime, &owners[0]) == NULL;
    claimed[1] = rducks_queue_pop_owner_request(&runtime, &owners[1]);
    pass &= claimed[1] && claimed[1]->meta == &states[1].pending;
    pass &= runtime.queue_running_current == 4U && runtime.queue_pending_current == 0U;
    /* Completion order differs from publication order; every submitter still
     * receives its own completion and releases its own borrowed stack. */
    const size_t completion_order[] = {3, 2, 1, 0};
    for (size_t i = 0; i < 4; i++) {
        size_t j = completion_order[i];
        if (claimed[j]) rducks_queue_finish_request(&runtime, claimed[j], 1, NULL);
    }
    for (size_t i = 0; i < 4; i++) {
        pthread_join(workers[i], NULL);
        pass &= states[i].ok && atomic_load(&states[i].pending) == 0;
    }
    pass &= runtime.queue_timeouts == 0U && runtime.queue_submitted == 4U && runtime.queue_executed == 4U;
    pass &= clean_runtime(&runtime);
    printf("owner pump and legacy drain select only their requests: %s\n", pass ? "PASS" : "FAIL");
    return pass;
}
#endif

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    int ok = check(NOTIFICATION_STORM, "600 notifications do not exhaust the elapsed deadline");
    if (argc > 1 && strcmp(argv[1], "--storm-only") == 0) return ok ? 0 : 1;
    ok &= check(ELAPSED_DEADLINE, "elapsed deadline removes a pending request");
    ok &= check(PENDING_CANCEL, "cancellation removes a pending request");
    ok &= check(RUNNING_CANCEL, "running request survives cancellation and deadline until DONE");
#ifdef RDUCKS_TEST_MANAGED_QUEUE
    ok &= check(MANAGED_PAUSE, "managed pending request survives elapsed deadline and unrelated cancellation");
    ok &= check(MANAGED_STOP, "owner stop removes pending requests and rejects later admission");
    ok &= check(MANAGED_RUNNING_STOP, "managed running request holds worker storage through owner stop until DONE");
    ok &= check_owner_filter();
#endif
    return ok ? 0 : 1;
}
