# Review follow-up checklist

This checklist tracks the issues raised in the follow-up review summary
and the current resolution status.

## High priority

4.1 NNG worker socket cleanup on initialization failure.

- `R/provider_nng.R` now installs cleanup handlers before creating the
  REP context, so a context/allocation failure still closes the socket.

10.1 Arrow IPC/NNG per-call timeout.

- Native NNG clients set send/receive timeouts from `ipc_timeout`;
  `inst/tinytest/test_duckdb_runtime_nng_batch_contract.R` now exercises
  an execute request whose worker accepts the request but delays the
  response.

10.2 / 11.1 NNG client-pool teardown quiescence.

- `tools/ext/src/rducks_nng.c` treats `begin_close()` as the pool ref
  barrier and no longer restores a half-closed pool when global quiesce
  races with destruction.

## Medium priority

3.2 Long DuckDB result errors silently truncated.

- Added `rducks_copy_error_message()` so result/prepare/pending errors
  copied into fixed buffers get an explicit `... [truncated]` marker
  instead of silent suffix loss.

4.2 `rducks_parallel_range` unchecked validity writes.

- Current `rducks_parallel_range` no longer calls
  `duckdb_validity_set_row_validity`; this finding is stale for the
  current source.

11.4 O(n^2) aggregate distinct-state deduplication.

- Vectorized aggregate update now sorts state pointers and
  binary-searches group IDs instead of linearly scanning the growing
  distinct-state array for every row.

11.6 O(n) UDF stat lookup scan.

- Runtime UDF registration now maintains a per-runtime name hash table
  for exact lookup by UDF name.

12.2 Streaming table bind close on non-main-thread destruction.

- Preserved-release queue entries can request table-stream close;
  off-main bind destruction now queues close+release for the recorded R
  thread.

12.3 O(n \* levels) enum output scan.

- Type descriptors now build field-name hash indexes; enum output and
  UNION tag lookup use hashed lookup. Matching R factors also keep the
  direct level-index fast path.

13.2 Running-timeout stub documentation.

- Already documented in `tools/ext/src/rducks_surfaces.c` and the
  function catalog: running same-process queued callbacks are not
  cancellable safely.

## Coverage gaps

14.2 `exception_handling = "return_null"` with owned LIST/STRUCT
results.

- Added queued `arrow_c` LIST and STRUCT return-null checks in
  `inst/tinytest/test_duckdb_runtime_concurrent_queue.R`.

14.3 `rducks_runtime_refresh_connection` regression.

- Lifecycle tests now execute an existing UDF and register/execute a new
  UDF after enabling Rducks on a second connection to the same database.

14.4 Same-process concurrent extension-load race.

- The registration mutex fix is in native code. A deterministic
  same-process threaded R test is still not portable because calling
  DBI/R APIs concurrently from R worker threads is unsafe.

14.5 NNG pool destroy under truly concurrent release.

- The native ref barrier is fixed. Current tests cover timeout/release
  paths, but a deterministic concurrent native teardown stress remains
  outstanding.

14.6 Multi-row/multi-tag UNION `arrow_c`.

- Added multi-row UNION `arrow_c` coverage in
  `inst/tinytest/test_duckdb_runtime_enum_bit_union_blob.R`.

14.7 Streaming table bind lifecycle under early scan termination.

- Added a `LIMIT`/early-close stream test in
  `inst/tinytest/test_duckdb_runtime_table_function.R`.

14.8 Stat counter reset surface.

- Already covered by `inst/tinytest/test_duckdb_runtime_explain_udf.R`,
  which resets one UDF and all UDF counters through the SQL surface.

14.9 Multi-database / ATTACH isolation.

- Added ATTACH and two-live-database isolation coverage in
  `inst/tinytest/test_zzzz_duckdb_runtime_lifecycle.R`.
