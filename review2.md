# Rducks Fresh Review — rev2

This is a ground-up review of the codebase as it currently stands.  The prior
review (`review.md`) was written against an older state; the fixed items from
that review are listed briefly at the end as context.  All new findings have
fresh identifiers.

---

## Summary table

| ID   | File(s)                            | Severity | Short description |
|------|------------------------------------|----------|-------------------|
| R2-3 | `rducks_nng.c`                     | Medium   | Per-call `timeout_ms` silently ignored for already-open sockets |
| R2-4 | `rducks_table.c`                   | Medium   | `rducks_r_table_int64_scalar` precision loss for large i64 values |
| R2-5 | whole codebase                     | Medium   | Error messages silently truncated at small fixed buffer sizes |
| R2-6 | `rducks_table.c`                   | Medium   | Streaming table bind data freed on non-main thread while scan may still reference it |
| R2-7 | `rducks_runtime.c`                 | Low      | `rducks_preserved_release_snapshot` holds global lock during O(n) list walk |

---

## Detailed findings

### R2-3 · Medium — Per-call `timeout_ms` silently ignored for already-open sockets

**File:** `tools/ext/src/rducks_nng.c`, `rducks_nng_client_open_locked` (lines 202–228)
and `rducks_nng_client_request_reply_borrowed_locked` (lines 231+)

`rducks_nng_client_open_locked` sets `NNG_OPT_RECVTIMEO` and `NNG_OPT_SENDTIMEO`
on the socket at open time (lines 216–219).  Both
`rducks_nng_client_request_reply_borrowed_locked` and the pool acquire path pass
a per-call `timeout_ms`, but `rducks_nng_client_open_locked` returns early at
line 210 (`if (client->opened) return 1;`) when the socket is already open.

```c
static int rducks_nng_client_open_locked(rducks_nng_client_t *client, int timeout_ms, ...) {
    ...
    if (client->opened) return 1;   // ← timeout_ms never applied
    ...
    (void)nng_socket_set_ms(sock, NNG_OPT_RECVTIMEO, timeout_ms);
    (void)nng_socket_set_ms(sock, NNG_OPT_SENDTIMEO, timeout_ms);
```

The socket does have a receive timeout (set at first open), so calls will not
block indefinitely.  However, if the pool was constructed with a longer
(or shorter) effective timeout than the per-call caller intends, the per-call
value is silently discarded.  In practice the pool creation timeout and the
per-call timeout appear to be the same value, but the discrepancy is invisible
to callers and could become a real gap if those values diverge.

**Fix:** after opening a socket, or when re-using one, apply the per-call
`timeout_ms` via `nng_socket_set_ms` unconditionally so that the active
deadline always matches the caller's intent.

---

### R2-4 · Medium — Precision loss in `rducks_r_table_int64_scalar` for large values

**File:** `tools/ext/src/rducks_table.c`, lines 145–148

```c
static SEXP rducks_r_table_int64_scalar(int64_t value) {
    if (value >= (int64_t)INT32_MIN && value <= (int64_t)INT32_MAX) return Rf_ScalarInteger((int)value);
    return Rf_ScalarReal((double)value);   // ← lossy for |value| > 2^53
}
```

This function is called for `INTERVAL.micros` (line 445 of `rducks_table.c`).
Values with absolute magnitude above 2^53 lose low-order bits when cast to
`double`.  For example, an interval of `9 999 999 999 999 999 μs` (≈317 years)
would lose the last few microseconds silently.

The BIGINT table parameter path was separately fixed (now uses
`rducks_r_table_bigint_scalar`), but this generic helper is still used for
interval microseconds where precision matters.

**Fix:** use the same `rducks_r_table_bigint_scalar` path (which produces a
classed `rducks_bigint` string) for interval micros, or document the precision
limit explicitly.

---

### R2-5 · Medium — Error messages silently truncated at small fixed buffer sizes

**Files:** `tools/ext/src/rducks_udf_sql.c` (line 245: `char err[256]`),
`tools/ext/src/rducks_table.c` (multiple `char err[512]`),
`tools/ext/src/rducks_aggregate.c` (`rducks_r_aggregate_set_error`, 512 bytes),
`tools/ext/src/rducks_rc.c` (multiple `char err_msg[512]`).

`rducks_util.c` now provides `rducks_copy_error_message`, which appends
`" ... [truncated]"` when a message is cut.  However, the small stack `err`
buffers spread through the codebase are populated directly with `snprintf`,
not via `rducks_copy_error_message`.  When a user-facing error from R (e.g. a
long backtrace stored in the condition message) exceeds the buffer capacity, the
message is silently clipped with no truncation indicator.

In `rducks_udf_sql.c` the per-row registration loop uses only 256 bytes for
error messages, while `rducks_register_r_scalar` itself uses 512-byte buffers
internally.  A mismatch between caller and callee capacity means the callee's
longer message is always truncated in the caller's smaller buffer.

**Fix:** either increase the primary error buffer sizes (1–4 KiB), or route
all final DuckDB error writes through `rducks_copy_error_message` so truncation
is always marked.

---

### R2-6 · Medium — Streaming table bind data freed on non-main thread on scan abort

**File:** `tools/ext/src/rducks_table.c`, `rducks_r_table_bind_destroy` (lines 66–90)

When `bind->streaming == 1` and the destroy is called from a non-main thread
(e.g. on DuckDB's scan-abort / GC path), the code enqueues the R-level stream
close via `rducks_preserved_release_enqueue_table_stream(bind->result)` and then
immediately frees native-side allocations on the calling thread (lines 80–88):

```c
if (close_stream_on_release) {
    rducks_preserved_release_enqueue_table_stream(bind->result);
}
// then unconditionally on the calling thread:
if (bind->imported_chunk) duckdb_destroy_data_chunk(&bind->imported_chunk);
free(bind->column_names);
free(bind->column_descs);
free(bind);
```

If the main thread is concurrently executing a scan callback that has already
dereferenced `bind->column_descs` or `bind->imported_chunk` (e.g. mid-row
projection), and the non-main thread races to `free()` those pointers, the
result is a use-after-free.

This requires a concurrent scan in progress at the exact moment DuckDB triggers
the abort-side destroy, so severity is situational.

**Fix:** ensure `bind` and its child allocations are freed only after all
scan callbacks that reference them have completed, using a reference count or
a deferred-free queue analogous to `rducks_preserved_release_enqueue`.

---

### R2-7 · Low — `rducks_preserved_release_snapshot` holds the global lock during O(n) traversal

**File:** `tools/ext/src/rducks_runtime.c`, `rducks_preserved_release_snapshot` (lines 293–306)

To count the pending nodes in the preserved-release queue, the function acquires
`rducks_runtime_lock()` and traverses the entire queue while the lock is held.
This is called from the R-level `rducks_release_stats()` diagnostic surface, so
it is not on any hot path.

However, the global lock is the same lock used by `rducks_preserved_release_enqueue`,
which is called from DuckDB callback threads.  A large pending queue (e.g. after
many UDF calls have been issued but the main thread has not drained yet) can
cause the stats call to hold the lock for a non-trivial time and block enqueuers.

**Fix:** either walk the queue after unlocking with an atomic snapshot approach,
or document that `rducks_release_stats()` may transiently block callback threads
on large queues.

---

## Retracted findings

The following findings appeared in an earlier draft of this review and have been
retracted after verifying the code:

| Draft ID | Retraction reason |
|----------|-------------------|
| R2-1 (stack UAR in `rducks_queue_submit_scalar_via_worker_on_main`) | FALSE. `pthread_join` / `WaitForSingleObject` is called unconditionally after the spin loop (lines 487–492), guaranteeing the worker thread has exited before the stack frame is released. No use-after-return. |
| R2-2 (pool creation fail calls global quiesce) | FALSE. `rducks_nng_global_quiesce` holds the lifecycle lock throughout and resets `g_rducks_nng_quiescing` to 0 before unlocking whenever open pools or active ops are present (lines 166–176). No concurrent caller can observe the quiescing flag. No disruption to other pools. |
| R2-8 (NNG worker init fd leak) | FALSE. There is no `rducks_nng_worker_init` function. The actual socket-open failure path in `rducks_nng_client_open_locked` calls `nng_close(sock)` at line 223 before returning. No leak. |
| R2-9 (outer spin timeout < inner queue timeout causes spurious failure) | FALSE. After the spin loop, `pthread_join` blocks until the worker finishes regardless. The worker always sets `state.done = 1` (line 439) before returning, so the `if (!state.done)` error path at line 493 is dead code. |

---

## Previously fixed issues (confirmed resolved)

The following findings from the old review have been confirmed fixed in the
current codebase:

| Old ID | Fix confirmed |
|--------|--------------|
| 13.1 | BIGINT/UBIGINT table parameters now use `rducks_r_table_bigint_scalar` / `rducks_r_table_ubigint_scalar` (classed string path, no precision loss) |
| 13.3 | `rducks_runtime_refresh_connection` registry swap is done atomically under lock; streams/registry detached under lock and destroyed outside |
| 13.4 | Extension registration surface is wrapped in `rducks_registration_lock()` covering the full check-and-register block |
| 11.6 | `udf_registry_buckets` hash map added; `rducks_runtime_find_udf_locked` is now O(1) |
| 11.4 | `update_chunk` dedup now sorts + binary-searches in O(n log n) |
| 10.2/11.1 | `rducks_nng_client_pool_begin_close()` ref-barrier before socket teardown is in place |
| 8.3/5.1 | `rducks_rc_direct_view_init` merged (no duplicate functions) |
| 6.1 | `register.R` checks `is.function(fun)` before proceeding |
| 10.3 | NNG wire validates arg-count with `rducks_nng_dynamic_arg_count_limit` |
| 12.3 | `rducks_type_desc_find_field_index` uses a field hash map; enum level lookup is now O(1) average |
| 4.2  | `rducks_parallel_range_function` writes only UBIGINT values which are always valid; no validity write required |

---

## Notes on scope

The following files or areas were not read in full depth and may contain
additional findings:

- `rducks_rc.c` lines 1200–3986 (inner scalar/vectorized writeback paths,
  queue-path snapshot/writeback, and RIPC buffer handling). The sections
  reviewed (lines 1–1199) appear correct.
- `rducks_arrow.c` lines 200–1615 (RIPC IPC decode path and Arrow C Data
  export).
- `inst/tinytest/` test files (not reviewed; used only for pass/fail
  confirmation of features, not for additional coverage gap analysis).
