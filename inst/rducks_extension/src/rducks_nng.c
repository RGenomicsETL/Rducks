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
static atomic_uint_fast64_t g_rducks_nng_self_test_counter = 1;

static void rducks_nng_format_error(char *err_msg, size_t err_cap, const char *context, int rc) {
    if (!err_msg || err_cap == 0) return;
    snprintf(err_msg, err_cap, "%s: %s (%d)", context ? context : "NNG error", nng_strerror(rc), rc);
}

static int rducks_nng_wait_or_timeout(nng_time deadline_ms, const char *context, char *err_msg, size_t err_cap) {
    nng_time now = nng_clock();
    if (now >= deadline_ms) {
        if (err_msg && err_cap) snprintf(err_msg, err_cap, "%s timed out", context ? context : "NNG operation");
        return 0;
    }
    nng_msleep((nng_duration)((deadline_ms - now) < 5 ? (deadline_ms - now) : 5));
    return 1;
}

static int rducks_nng_request_reply(const char *endpoint,
                                    const uint8_t *request, size_t request_size,
                                    int timeout_ms,
                                    uint8_t **response_out, size_t *response_size_out,
                                    char *err_msg, size_t err_cap) {
    nng_socket sock = NNG_SOCKET_INITIALIZER;
    nng_msg *send_msg = NULL;
    nng_msg *recv_msg = NULL;
    void *recv_buf = NULL;
    size_t recv_len = 0;
    int rc;
    if (response_out) *response_out = NULL;
    if (response_size_out) *response_size_out = 0;
    if (!endpoint || !endpoint[0] || !request || request_size == 0 || !response_out || !response_size_out) {
        snprintf(err_msg, err_cap, "invalid Rducks NNG request");
        return 0;
    }
    rc = nng_req0_open(&sock);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_req0_open failed", rc);
        return 0;
    }
    if (timeout_ms > 0) {
        (void)nng_socket_set_ms(sock, NNG_OPT_RECVTIMEO, timeout_ms);
        (void)nng_socket_set_ms(sock, NNG_OPT_SENDTIMEO, timeout_ms);
        rc = nng_dial(sock, endpoint, NULL, NNG_FLAG_NONBLOCK);
    } else {
        rc = nng_dial(sock, endpoint, NULL, 0);
    }
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_dial failed", rc);
        nng_close(sock);
        return 0;
    }

    rc = nng_msg_alloc(&send_msg, 0);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_msg_alloc failed", rc);
        nng_close(sock);
        return 0;
    }
    rc = nng_msg_append(send_msg, request, request_size);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_msg_append failed", rc);
        nng_msg_free(send_msg);
        nng_close(sock);
        return 0;
    }
    rc = nng_sendmsg(sock, send_msg, 0);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_sendmsg failed", rc);
        nng_msg_free(send_msg);
        nng_close(sock);
        return 0;
    }
    send_msg = NULL;
    rc = nng_recvmsg(sock, &recv_msg, 0);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_recvmsg failed", rc);
        nng_close(sock);
        return 0;
    }

    recv_len = nng_msg_len(recv_msg);
    recv_buf = nng_msg_body(recv_msg);
    *response_out = (uint8_t *)malloc(recv_len ? recv_len : 1U);
    if (!*response_out) {
        snprintf(err_msg, err_cap, "out of memory copying Rducks NNG response");
        nng_msg_free(recv_msg);
        nng_close(sock);
        return 0;
    }
    if (recv_len) memcpy(*response_out, recv_buf, recv_len);
    *response_size_out = recv_len;
    nng_msg_free(recv_msg);
    nng_close(sock);
    return 1;
}

static int rducks_nng_pair_self_test(char *err_msg, size_t err_cap) {
    nng_socket listener = NNG_SOCKET_INITIALIZER;
    nng_socket dialer = NNG_SOCKET_INITIALIZER;
    int listener_open = 0;
    int dialer_open = 0;
    int rc;
    char url[128];
    char recv_buf[64];
    size_t recv_len = sizeof(recv_buf);
    const char payload[] = "rducks-nng-self-test";
    uint64_t id = atomic_fetch_add_explicit(&g_rducks_nng_self_test_counter, 1, memory_order_relaxed);

    snprintf(url, sizeof(url), "inproc://rducks-nng-self-test-%llu", (unsigned long long)id);

    rc = nng_pair0_open(&listener);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_pair0_open(listener) failed", rc);
        return 0;
    }
    listener_open = 1;
    rc = nng_pair0_open(&dialer);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_pair0_open(dialer) failed", rc);
        goto fail;
    }
    dialer_open = 1;

    (void)nng_socket_set_ms(listener, NNG_OPT_RECVTIMEO, 1000);
    (void)nng_socket_set_ms(listener, NNG_OPT_SENDTIMEO, 1000);
    (void)nng_socket_set_ms(dialer, NNG_OPT_RECVTIMEO, 1000);
    (void)nng_socket_set_ms(dialer, NNG_OPT_SENDTIMEO, 1000);

    rc = nng_listen(listener, url, NULL, 0);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_listen(inproc) failed", rc);
        goto fail;
    }
    rc = nng_dial(dialer, url, NULL, NNG_FLAG_NONBLOCK);
    if (rc != 0) {
        rducks_nng_format_error(err_msg, err_cap, "nng_dial(inproc) failed", rc);
        goto fail;
    }
    {
        nng_time deadline_ms = nng_clock() + 1000U;
        for (;;) {
            rc = nng_send(dialer, (void *)payload, sizeof(payload), NNG_FLAG_NONBLOCK);
            if (rc == 0) break;
            if (rc != NNG_EAGAIN) {
                rducks_nng_format_error(err_msg, err_cap, "nng_send(self-test) failed", rc);
                goto fail;
            }
            if (!rducks_nng_wait_or_timeout(deadline_ms, "nng_send(self-test)", err_msg, err_cap)) goto fail;
        }
        memset(recv_buf, 0, sizeof(recv_buf));
        for (;;) {
            rc = nng_recv(listener, recv_buf, &recv_len, NNG_FLAG_NONBLOCK);
            if (rc == 0) break;
            if (rc != NNG_EAGAIN) {
                rducks_nng_format_error(err_msg, err_cap, "nng_recv(self-test) failed", rc);
                goto fail;
            }
            if (!rducks_nng_wait_or_timeout(deadline_ms, "nng_recv(self-test)", err_msg, err_cap)) goto fail;
        }
    }
    if (recv_len != sizeof(payload) || memcmp(recv_buf, payload, sizeof(payload)) != 0) {
        snprintf(err_msg, err_cap, "NNG self-test payload mismatch");
        goto fail;
    }

    nng_close(dialer);
    nng_close(listener);
    return 1;

fail:
    if (dialer_open) nng_close(dialer);
    if (listener_open) nng_close(listener);
    return 0;
}
#else
static int rducks_nng_request_reply(const char *endpoint,
                                    const uint8_t *request, size_t request_size,
                                    int timeout_ms,
                                    uint8_t **response_out, size_t *response_size_out,
                                    char *err_msg, size_t err_cap) {
    (void)endpoint;
    (void)request;
    (void)request_size;
    (void)timeout_ms;
    if (response_out) *response_out = NULL;
    if (response_size_out) *response_size_out = 0;
    if (err_msg && err_cap) snprintf(err_msg, err_cap, "vendored NNG support was not compiled into this Rducks extension");
    return 0;
}

static int rducks_nng_pair_self_test(char *err_msg, size_t err_cap) {
    if (err_msg && err_cap) snprintf(err_msg, err_cap, "vendored NNG support was not compiled into this Rducks extension");
    return 0;
}
#endif

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
