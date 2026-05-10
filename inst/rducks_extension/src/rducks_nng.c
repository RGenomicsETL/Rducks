/* Included by ../rducks_extension.c. */

#ifdef RDUCKS_WITH_NNG
#include <nng/nng.h>
#include <nng/protocol/pair0/pair.h>
#include <nng/protocol/reqrep0/req.h>
#include <nng/protocol/reqrep0/rep.h>
#include <nng/protocol/pipeline0/push.h>
#include <nng/protocol/pipeline0/pull.h>
#include <nng/protocol/pubsub0/pub.h>
#include <nng/protocol/pubsub0/sub.h>
#endif

static int rducks_nng_enabled_native(void) {
#ifdef RDUCKS_WITH_NNG
    return 1;
#else
    return 0;
#endif
}

static const char *rducks_nng_version_native(void) {
#ifdef RDUCKS_WITH_NNG
    return nng_version();
#else
    return "disabled";
#endif
}

#ifdef RDUCKS_WITH_NNG
#ifdef _WIN32
typedef struct rducks_nng_mutex {
    CRITICAL_SECTION cs;
} rducks_nng_mutex_t;
typedef struct rducks_nng_cond {
    CONDITION_VARIABLE cv;
} rducks_nng_cond_t;

static void rducks_nng_mutex_init(rducks_nng_mutex_t *mutex) { InitializeCriticalSection(&mutex->cs); }
static void rducks_nng_mutex_destroy(rducks_nng_mutex_t *mutex) { DeleteCriticalSection(&mutex->cs); }
static void rducks_nng_mutex_lock(rducks_nng_mutex_t *mutex) { EnterCriticalSection(&mutex->cs); }
static void rducks_nng_mutex_unlock(rducks_nng_mutex_t *mutex) { LeaveCriticalSection(&mutex->cs); }
static void rducks_nng_cond_init(rducks_nng_cond_t *cond) { InitializeConditionVariable(&cond->cv); }
static void rducks_nng_cond_destroy(rducks_nng_cond_t *cond) { (void)cond; }
static void rducks_nng_cond_wait(rducks_nng_cond_t *cond, rducks_nng_mutex_t *mutex) { SleepConditionVariableCS(&cond->cv, &mutex->cs, INFINITE); }
static void rducks_nng_cond_broadcast(rducks_nng_cond_t *cond) { WakeAllConditionVariable(&cond->cv); }

static CRITICAL_SECTION g_rducks_nng_lifecycle_lock;
static INIT_ONCE g_rducks_nng_lifecycle_once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK rducks_nng_lifecycle_init_once(PINIT_ONCE once, PVOID param, PVOID *context) {
    (void)once;
    (void)param;
    (void)context;
    InitializeCriticalSection(&g_rducks_nng_lifecycle_lock);
    return TRUE;
}
static void rducks_nng_lifecycle_lock(void) {
    InitOnceExecuteOnce(&g_rducks_nng_lifecycle_once, rducks_nng_lifecycle_init_once, NULL, NULL);
    EnterCriticalSection(&g_rducks_nng_lifecycle_lock);
}
static void rducks_nng_lifecycle_unlock(void) { LeaveCriticalSection(&g_rducks_nng_lifecycle_lock); }
#else
typedef struct rducks_nng_mutex {
    pthread_mutex_t mutex;
} rducks_nng_mutex_t;
typedef struct rducks_nng_cond {
    pthread_cond_t cond;
} rducks_nng_cond_t;

static void rducks_nng_mutex_init(rducks_nng_mutex_t *mutex) { pthread_mutex_init(&mutex->mutex, NULL); }
static void rducks_nng_mutex_destroy(rducks_nng_mutex_t *mutex) { pthread_mutex_destroy(&mutex->mutex); }
static void rducks_nng_mutex_lock(rducks_nng_mutex_t *mutex) { pthread_mutex_lock(&mutex->mutex); }
static void rducks_nng_mutex_unlock(rducks_nng_mutex_t *mutex) { pthread_mutex_unlock(&mutex->mutex); }
static void rducks_nng_cond_init(rducks_nng_cond_t *cond) { pthread_cond_init(&cond->cond, NULL); }
static void rducks_nng_cond_destroy(rducks_nng_cond_t *cond) { pthread_cond_destroy(&cond->cond); }
static void rducks_nng_cond_wait(rducks_nng_cond_t *cond, rducks_nng_mutex_t *mutex) { pthread_cond_wait(&cond->cond, &mutex->mutex); }
static void rducks_nng_cond_broadcast(rducks_nng_cond_t *cond) { pthread_cond_broadcast(&cond->cond); }

static pthread_mutex_t g_rducks_nng_lifecycle_lock = PTHREAD_MUTEX_INITIALIZER;
static void rducks_nng_lifecycle_lock(void) { pthread_mutex_lock(&g_rducks_nng_lifecycle_lock); }
static void rducks_nng_lifecycle_unlock(void) { pthread_mutex_unlock(&g_rducks_nng_lifecycle_lock); }
#endif

static uint64_t g_rducks_nng_active_ops = 0;
static uint64_t g_rducks_nng_open_pools = 0;
static int g_rducks_nng_quiescing = 0;

struct rducks_nng_client {
    char *endpoint;
    nng_socket sock;
    int opened;
    int mutex_initialized;
    rducks_nng_mutex_t mutex;
    atomic_uint_fast64_t inflight;
};

typedef struct rducks_nng_client rducks_nng_client_t;

struct rducks_nng_client_pool {
    rducks_nng_client_t *clients;
    size_t count;
    int timeout_ms;
    uint64_t max_pending;
    rducks_nng_mutex_t lock;
    rducks_nng_cond_t cv;
    int sync_initialized;
    int closing;
    uint64_t refs;
    atomic_uint_fast64_t next_ticket;
    atomic_uint_fast64_t pending;
};

static void rducks_nng_format_error(char *err_msg, size_t err_cap, const char *context, int rc) {
    if (!err_msg || err_cap == 0) return;
    snprintf(err_msg, err_cap, "%s: %s (%d)", context ? context : "NNG error", nng_strerror(rc), rc);
}

static int rducks_nng_enter_op(const char *context, char *err_msg, size_t err_cap) {
    int ok = 1;
    rducks_nng_lifecycle_lock();
    if (g_rducks_nng_quiescing) {
        if (err_msg && err_cap) snprintf(err_msg, err_cap, "%s while Rducks NNG is quiescing", context ? context : "NNG operation");
        ok = 0;
    } else {
        g_rducks_nng_active_ops++;
    }
    rducks_nng_lifecycle_unlock();
    return ok;
}

static void rducks_nng_leave_op(void) {
    rducks_nng_lifecycle_lock();
    if (g_rducks_nng_active_ops > 0) g_rducks_nng_active_ops--;
    rducks_nng_lifecycle_unlock();
}

static void rducks_nng_pool_count_add(void) {
    rducks_nng_lifecycle_lock();
    g_rducks_nng_open_pools++;
    rducks_nng_lifecycle_unlock();
}

static void rducks_nng_pool_count_done(void) {
    rducks_nng_lifecycle_lock();
    if (g_rducks_nng_open_pools > 0) g_rducks_nng_open_pools--;
    rducks_nng_lifecycle_unlock();
}

static int rducks_nng_global_quiesce_allow_open(uint64_t allowed_open_pools,
                                                char *err_msg, size_t err_cap) {
    rducks_nng_lifecycle_lock();
    if (g_rducks_nng_active_ops != 0 || g_rducks_nng_open_pools > allowed_open_pools) {
        if (err_msg && err_cap) {
            snprintf(err_msg, err_cap,
                     "Rducks NNG cannot quiesce with %llu active operation(s) and %llu open client pool(s)",
                     (unsigned long long)g_rducks_nng_active_ops,
                     (unsigned long long)g_rducks_nng_open_pools);
        }
        rducks_nng_lifecycle_unlock();
        return 0;
    }
    /* Do not call nng_fini() during ordinary R/DuckDB runtime teardown.
     * NNG documents fini as an atexit/just-before-dlclose operation; in an R
     * session, quiescing a connection can be followed by more registrations.
     * Socket/pool shutdown above is the runtime quiesce point.
     */
    rducks_nng_lifecycle_unlock();
    return 1;
}

static int rducks_nng_global_quiesce(char *err_msg, size_t err_cap) {
    return rducks_nng_global_quiesce_allow_open(0U, err_msg, err_cap);
}

static void rducks_nng_client_close_locked(rducks_nng_client_t *client) {
    if (!client) return;
    if (client->opened) {
        nng_close(client->sock);
        client->sock = (nng_socket)NNG_SOCKET_INITIALIZER;
        client->opened = 0;
    }
}

static int rducks_nng_client_open_locked(rducks_nng_client_t *client, int timeout_ms,
                                         char *err_msg, size_t err_cap) {
    nng_socket sock = NNG_SOCKET_INITIALIZER;
    int rc;
    if (!client || !client->endpoint || !client->endpoint[0]) {
        if (err_msg && err_cap) snprintf(err_msg, err_cap, "invalid Rducks NNG endpoint");
        return 0;
    }
    if (client->opened) return 1;
    rc = nng_req0_open(&sock);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_req0_open failed", rc);
        return 0;
    }
    if (timeout_ms > 0) {
        (void)nng_socket_set_ms(sock, NNG_OPT_RECVTIMEO, timeout_ms);
        (void)nng_socket_set_ms(sock, NNG_OPT_SENDTIMEO, timeout_ms);
    }
    rc = nng_dial(sock, client->endpoint, NULL, timeout_ms > 0 ? NNG_FLAG_NONBLOCK : 0);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_dial failed", rc);
        nng_close(sock);
        return 0;
    }
    client->sock = sock;
    client->opened = 1;
    return 1;
}

static int rducks_nng_client_request_reply_locked(rducks_nng_client_t *client,
                                                  const uint8_t *request, size_t request_size,
                                                  int timeout_ms,
                                                  uint8_t **response_out, size_t *response_size_out,
                                                  char *err_msg, size_t err_cap) {
    nng_msg *send_msg = NULL;
    nng_msg *recv_msg = NULL;
    void *recv_buf = NULL;
    size_t recv_len = 0;
    int rc;

    if (response_out) *response_out = NULL;
    if (response_size_out) *response_size_out = 0;
    if (!client || !request || request_size == 0 || !response_out || !response_size_out) {
        if (err_msg && err_cap) snprintf(err_msg, err_cap, "invalid Rducks NNG request");
        return 0;
    }
    if (!rducks_nng_client_open_locked(client, timeout_ms, err_msg, err_cap)) return 0;

    rc = nng_msg_alloc(&send_msg, 0);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_msg_alloc failed", rc);
        return 0;
    }
    rc = nng_msg_append(send_msg, request, request_size);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_msg_append failed", rc);
        nng_msg_free(send_msg);
        return 0;
    }
    rc = nng_sendmsg(client->sock, send_msg, 0);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_sendmsg failed", rc);
        nng_msg_free(send_msg);
        rducks_nng_client_close_locked(client);
        return 0;
    }
    send_msg = NULL;

    rc = nng_recvmsg(client->sock, &recv_msg, 0);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_recvmsg failed", rc);
        rducks_nng_client_close_locked(client);
        return 0;
    }

    recv_len = nng_msg_len(recv_msg);
    recv_buf = nng_msg_body(recv_msg);
    *response_out = (uint8_t *)malloc(recv_len ? recv_len : 1U);
    if (!*response_out) {
        if (err_msg && err_cap) snprintf(err_msg, err_cap, "out of memory copying Rducks NNG response");
        nng_msg_free(recv_msg);
        return 0;
    }
    if (recv_len) memcpy(*response_out, recv_buf, recv_len);
    *response_size_out = recv_len;
    nng_msg_free(recv_msg);
    return 1;
}

static void rducks_nng_client_destroy(rducks_nng_client_t *client) {
    if (!client) return;
    if (client->mutex_initialized) rducks_nng_mutex_lock(&client->mutex);
    rducks_nng_client_close_locked(client);
    free(client->endpoint);
    client->endpoint = NULL;
    if (client->mutex_initialized) {
        rducks_nng_mutex_unlock(&client->mutex);
        rducks_nng_mutex_destroy(&client->mutex);
        client->mutex_initialized = 0;
    }
}

static int rducks_nng_client_pool_acquire(rducks_nng_client_pool_t *pool, char *err_msg, size_t err_cap) {
    if (!pool || !pool->sync_initialized) {
        if (err_msg && err_cap) snprintf(err_msg, err_cap, "RIPC client pool is not configured");
        return 0;
    }
    rducks_nng_mutex_lock(&pool->lock);
    if (pool->closing) {
        rducks_nng_mutex_unlock(&pool->lock);
        if (err_msg && err_cap) snprintf(err_msg, err_cap, "RIPC client pool is closing");
        return 0;
    }
    pool->refs++;
    rducks_nng_mutex_unlock(&pool->lock);
    return 1;
}

static void rducks_nng_client_pool_release(rducks_nng_client_pool_t *pool) {
    if (!pool || !pool->sync_initialized) return;
    rducks_nng_mutex_lock(&pool->lock);
    if (pool->refs > 0U) pool->refs--;
    if (pool->closing && pool->refs == 0U) rducks_nng_cond_broadcast(&pool->cv);
    rducks_nng_mutex_unlock(&pool->lock);
}

static void rducks_nng_client_pool_begin_close(rducks_nng_client_pool_t *pool) {
    if (!pool || !pool->sync_initialized) return;
    rducks_nng_mutex_lock(&pool->lock);
    pool->closing = 1;
    while (pool->refs > 0U) rducks_nng_cond_wait(&pool->cv, &pool->lock);
    rducks_nng_mutex_unlock(&pool->lock);
}

static void rducks_nng_client_pool_sync_destroy(rducks_nng_client_pool_t *pool) {
    if (!pool || !pool->sync_initialized) return;
    rducks_nng_cond_destroy(&pool->cv);
    rducks_nng_mutex_destroy(&pool->lock);
    pool->sync_initialized = 0;
}

static rducks_nng_client_pool_t *rducks_nng_client_pool_new(char **endpoints, size_t endpoint_count,
                                                            int timeout_ms, uint64_t max_pending,
                                                            char *err_msg, size_t err_cap) {
    rducks_nng_client_pool_t *pool = NULL;
    size_t initialized = 0;
    if (!endpoints || endpoint_count == 0U) {
        if (err_msg && err_cap) snprintf(err_msg, err_cap, "RIPC endpoint pool is empty");
        return NULL;
    }
    if (!rducks_nng_enter_op("create Rducks NNG client pool", err_msg, err_cap)) return NULL;

    pool = (rducks_nng_client_pool_t *)calloc(1, sizeof(*pool));
    if (!pool) {
        if (err_msg && err_cap) snprintf(err_msg, err_cap, "out of memory allocating Rducks NNG client pool");
        goto fail;
    }
    pool->clients = (rducks_nng_client_t *)calloc(endpoint_count, sizeof(*pool->clients));
    if (!pool->clients) {
        if (err_msg && err_cap) snprintf(err_msg, err_cap, "out of memory allocating Rducks NNG clients");
        goto fail;
    }
    pool->count = endpoint_count;
    pool->timeout_ms = timeout_ms;
    pool->max_pending = max_pending == 0U ? 1U : max_pending;
    rducks_nng_mutex_init(&pool->lock);
    rducks_nng_cond_init(&pool->cv);
    pool->sync_initialized = 1;
    atomic_init(&pool->next_ticket, 0U);
    atomic_init(&pool->pending, 0U);

    for (size_t i = 0; i < endpoint_count; i++) {
        if (!endpoints[i] || !endpoints[i][0]) {
            if (err_msg && err_cap) snprintf(err_msg, err_cap, "RIPC endpoint %llu is empty", (unsigned long long)i + 1ULL);
            goto fail;
        }
        pool->clients[i].endpoint = rducks_strdup_len(endpoints[i], strlen(endpoints[i]));
        if (!pool->clients[i].endpoint) {
            if (err_msg && err_cap) snprintf(err_msg, err_cap, "out of memory copying Rducks NNG endpoint");
            goto fail;
        }
        rducks_nng_mutex_init(&pool->clients[i].mutex);
        pool->clients[i].mutex_initialized = 1;
        atomic_init(&pool->clients[i].inflight, 0U);
        rducks_nng_mutex_lock(&pool->clients[i].mutex);
        if (!rducks_nng_client_open_locked(&pool->clients[i], timeout_ms, err_msg, err_cap)) {
            rducks_nng_mutex_unlock(&pool->clients[i].mutex);
            goto fail;
        }
        rducks_nng_mutex_unlock(&pool->clients[i].mutex);
        initialized++;
    }
    (void)initialized;
    rducks_nng_pool_count_add();
    rducks_nng_leave_op();
    return pool;

fail:
    if (pool) {
        if (pool->clients) {
            for (size_t i = 0; i < endpoint_count; i++) rducks_nng_client_destroy(&pool->clients[i]);
            free(pool->clients);
        }
        rducks_nng_client_pool_sync_destroy(pool);
        free(pool);
    }
    rducks_nng_leave_op();
    (void)rducks_nng_global_quiesce(NULL, 0);
    return NULL;
}

static void rducks_nng_client_pool_destroy(rducks_nng_client_pool_t **pool_ptr) {
    rducks_nng_client_pool_t *pool;
    if (!pool_ptr || !*pool_ptr) return;
    pool = *pool_ptr;
    *pool_ptr = NULL;
    rducks_nng_client_pool_begin_close(pool);
    if (!rducks_nng_enter_op("destroy Rducks NNG client pool", NULL, 0)) {
        if (pool->sync_initialized) {
            rducks_nng_mutex_lock(&pool->lock);
            pool->closing = 0;
            rducks_nng_mutex_unlock(&pool->lock);
        }
        *pool_ptr = pool;
        return;
    }
    if (pool->clients) {
        for (size_t i = 0; i < pool->count; i++) rducks_nng_client_destroy(&pool->clients[i]);
        free(pool->clients);
    }
    rducks_nng_client_pool_sync_destroy(pool);
    free(pool);
    rducks_nng_pool_count_done();
    rducks_nng_leave_op();
    (void)rducks_nng_global_quiesce(NULL, 0);
}

static size_t rducks_nng_client_pool_choose(rducks_nng_client_pool_t *pool) {
    uint64_t ticket;
    uint64_t best_load = UINT64_MAX;
    size_t best = 0;
    if (!pool || pool->count == 0U) return 0U;
    ticket = (uint64_t)atomic_fetch_add_explicit(&pool->next_ticket, 1U, memory_order_relaxed);
    best = (size_t)(ticket % pool->count);
    for (size_t k = 0; k < pool->count; k++) {
        size_t idx = (best + k) % pool->count;
        uint64_t load = (uint64_t)atomic_load_explicit(&pool->clients[idx].inflight, memory_order_relaxed);
        if (load < best_load) {
            best_load = load;
            best = idx;
            if (load == 0U) break;
        }
    }
    return best;
}

static int rducks_nng_client_pool_request_reply(rducks_nng_client_pool_t *pool,
                                                const uint8_t *request, size_t request_size,
                                                uint8_t **response_out, size_t *response_size_out,
                                                char *err_msg, size_t err_cap) {
    rducks_nng_client_t *client;
    size_t idx;
    uint64_t pending;
    int ok;

    if (response_out) *response_out = NULL;
    if (response_size_out) *response_size_out = 0;
    if (!pool || !pool->clients || pool->count == 0U) {
        if (err_msg && err_cap) snprintf(err_msg, err_cap, "RIPC client pool is not configured");
        return 0;
    }
    if (!rducks_nng_client_pool_acquire(pool, err_msg, err_cap)) return 0;

    pending = (uint64_t)atomic_fetch_add_explicit(&pool->pending, 1U, memory_order_relaxed) + 1U;
    if (pool->max_pending != UINT64_MAX && pending > pool->max_pending) {
        atomic_fetch_sub_explicit(&pool->pending, 1U, memory_order_relaxed);
        if (err_msg && err_cap) {
            snprintf(err_msg, err_cap,
                     "RIPC pending request limit exceeded (%llu > %llu)",
                     (unsigned long long)pending,
                     (unsigned long long)pool->max_pending);
        }
        rducks_nng_client_pool_release(pool);
        return 0;
    }

    if (!rducks_nng_enter_op("Rducks NNG request", err_msg, err_cap)) {
        atomic_fetch_sub_explicit(&pool->pending, 1U, memory_order_relaxed);
        rducks_nng_client_pool_release(pool);
        return 0;
    }

    idx = rducks_nng_client_pool_choose(pool);
    client = &pool->clients[idx];
    atomic_fetch_add_explicit(&client->inflight, 1U, memory_order_relaxed);
    rducks_nng_mutex_lock(&client->mutex);
    ok = rducks_nng_client_request_reply_locked(client, request, request_size, pool->timeout_ms,
                                                response_out, response_size_out, err_msg, err_cap);
    rducks_nng_mutex_unlock(&client->mutex);
    atomic_fetch_sub_explicit(&client->inflight, 1U, memory_order_relaxed);
    rducks_nng_leave_op();
    atomic_fetch_sub_explicit(&pool->pending, 1U, memory_order_relaxed);
    rducks_nng_client_pool_release(pool);
    return ok;
}

static int rducks_nng_pair_self_test_impl(char *err_msg, size_t err_cap) {
    nng_socket pair_sock = NNG_SOCKET_INITIALIZER;
    nng_socket req_sock = NNG_SOCKET_INITIALIZER;
    nng_socket rep_sock = NNG_SOCKET_INITIALIZER;
    int pair_open = 0;
    int req_open = 0;
    int rep_open = 0;
    int rc;

    /* Keep this diagnostic deliberately local to protocol/socket creation.
     * Real transport I/O is covered by the NNG provider tests.  A connected
     * inproc self-test can wedge in nng_close() after prior transport teardown
     * on some NNG builds, which makes the diagnostic less reliable than the
     * actual request/reply execution path.
     */
    rc = nng_pair0_open(&pair_sock);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_pair0_open failed", rc);
        return 0;
    }
    pair_open = 1;
    rc = nng_req0_open(&req_sock);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_req0_open failed", rc);
        goto fail;
    }
    req_open = 1;
    rc = nng_rep0_open(&rep_sock);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_rep0_open failed", rc);
        goto fail;
    }
    rep_open = 1;

    nng_close(rep_sock);
    nng_close(req_sock);
    nng_close(pair_sock);
    return 1;

fail:
    if (rep_open) nng_close(rep_sock);
    if (req_open) nng_close(req_sock);
    if (pair_open) nng_close(pair_sock);
    return 0;
}

static int rducks_nng_pair_self_test(char *err_msg, size_t err_cap) {
    int ok;
    if (!rducks_nng_enter_op("Rducks NNG self-test", err_msg, err_cap)) return 0;
    ok = rducks_nng_pair_self_test_impl(err_msg, err_cap);
    rducks_nng_leave_op();
    if (ok) (void)rducks_nng_global_quiesce(NULL, 0);
    return ok;
}
#else
struct rducks_nng_client_pool {
    int disabled;
};

static rducks_nng_client_pool_t *rducks_nng_client_pool_new(char **endpoints, size_t endpoint_count,
                                                            int timeout_ms, uint64_t max_pending,
                                                            char *err_msg, size_t err_cap) {
    (void)endpoints;
    (void)endpoint_count;
    (void)timeout_ms;
    (void)max_pending;
    if (err_msg && err_cap) snprintf(err_msg, err_cap, "vendored NNG support was not compiled into this Rducks extension");
    return NULL;
}

static void rducks_nng_client_pool_destroy(rducks_nng_client_pool_t **pool_ptr) {
    if (pool_ptr) *pool_ptr = NULL;
}

static int rducks_nng_client_pool_request_reply(rducks_nng_client_pool_t *pool,
                                                const uint8_t *request, size_t request_size,
                                                uint8_t **response_out, size_t *response_size_out,
                                                char *err_msg, size_t err_cap) {
    (void)pool;
    (void)request;
    (void)request_size;
    if (response_out) *response_out = NULL;
    if (response_size_out) *response_size_out = 0;
    if (err_msg && err_cap) snprintf(err_msg, err_cap, "vendored NNG support was not compiled into this Rducks extension");
    return 0;
}

static int rducks_nng_global_quiesce(char *err_msg, size_t err_cap) {
    (void)err_msg;
    (void)err_cap;
    return 1;
}

static int rducks_nng_pair_self_test(char *err_msg, size_t err_cap) {
    if (err_msg && err_cap) snprintf(err_msg, err_cap, "vendored NNG support was not compiled into this Rducks extension");
    return 0;
}
#endif

static uint64_t rducks_nng_runtime_close_local_pools(rducks_runtime_entry_t *runtime) {
    rducks_r_scalar_meta_t *meta;
    uint64_t external_pools = 0U;
    if (!runtime) return 0U;
    rducks_runtime_lock();
    for (meta = runtime->udf_registry_head; meta; meta = meta->registry_next) {
        if (meta->ripc_external_endpoints) {
            if (meta->ripc_client_pool) external_pools++;
        } else {
            rducks_nng_client_pool_destroy(&meta->ripc_client_pool);
        }
    }
    rducks_runtime_unlock();
    return external_pools;
}

static void rducks_nng_enabled_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    (void)info;
    idx_t n = duckdb_data_chunk_get_size(input);
    bool *out = (bool *)duckdb_vector_get_data(output);
    bool enabled = rducks_nng_enabled_native() ? true : false;
    for (idx_t i = 0; i < n; i++) out[i] = enabled;
}

static void rducks_nng_version_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    (void)info;
    idx_t n = duckdb_data_chunk_get_size(input);
    const char *version = rducks_nng_version_native();
    for (idx_t i = 0; i < n; i++) duckdb_vector_assign_string_element(output, i, version);
}

static void rducks_nng_self_test_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    idx_t n = duckdb_data_chunk_get_size(input);
    bool *out = (bool *)duckdb_vector_get_data(output);
    int ok;
    char err[256];
    err[0] = '\0';
    if (!rducks_nng_enabled_native()) {
        for (idx_t i = 0; i < n; i++) out[i] = false;
        return;
    }
    ok = rducks_nng_pair_self_test(err, sizeof(err));
    if (!ok) {
        duckdb_scalar_function_set_error(info, err[0] ? err : "Rducks vendored NNG self-test failed");
        return;
    }
    for (idx_t i = 0; i < n; i++) out[i] = true;
}

static void rducks_nng_quiesce_scalar(duckdb_function_info info, duckdb_data_chunk input, duckdb_vector output) {
    rducks_runtime_entry_t *runtime = (rducks_runtime_entry_t *)duckdb_scalar_function_get_extra_info(info);
    idx_t n = duckdb_data_chunk_get_size(input);
    bool *out = (bool *)duckdb_vector_get_data(output);
    char err[256];
    uint64_t external_pools;
    int ok;
    err[0] = '\0';
    external_pools = rducks_nng_runtime_close_local_pools(runtime);
    ok = rducks_nng_global_quiesce_allow_open(external_pools, err, sizeof(err));
    if (!ok) {
        duckdb_scalar_function_set_error(info, err[0] ? err : "Rducks vendored NNG quiesce failed");
        return;
    }
    for (idx_t i = 0; i < n; i++) out[i] = true;
}
