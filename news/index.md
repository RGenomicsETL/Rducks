# Changelog

## Rducks 0.0.1

- Added a first-slice
  [`rducks_register_table()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_table.md)
  API for finite zero-argument R-backed DuckDB table functions. The
  native table-function path binds a declared output schema, calls the R
  function once on the recorded calling R thread, emits data-frame/list
  columns in chunks, and reports schema, length, and R errors through
  DuckDB.
- Added vendored NNG/Mbed TLS source management for the native
  worker-provider foundation. `tools/vendor_nng_mbedtls.R` pins and
  refreshes the vendored sources, source builds can statically link a
  hidden NNG client shim when CMake is available, and dev/test SQL
  diagnostics expose `rducks_nng_enabled()`, `rducks_nng_version()`, and
  `rducks_nng_self_test()`.
- Added vendored Apache Arrow nanoarrow C/IPC sources for the native
  `arrow_ipc + multiprocess_parallel` path. The vendored code is
  compiled with `-DNANOARROW_NAMESPACE=RducksNanoarrow`, flatcc runtime
  symbols are prefixed, and Rducks uses these local C symbols instead of
  path-loading the nanoarrow R package shared library. The NNG provider
  path launches local mirai/nanonext worker loops by default, supports
  explicit `ipc_endpoints`, and errors rather than changing to generic
  process backends, same-process execution, or R serialization.
- [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)
  now reports queue-pending, `arrow_c` input-snapshot, `arrow_c`
  owned-result-chunk, and RIPC diagnostic counters for future native
  provider work.
- Added
  [`rducks_reset_udf_counters()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_reset_udf_counters.md)
  to reset one UDF’s diagnostic counters or all native UDF counters in
  the current database runtime without unregistering catalog functions.
- UDF stat field discovery now comes from native
  `rducks_udf_stat_fields()`; the R-side field vector is only a
  documented compatibility list for sessions where that optional native
  discovery helper is unavailable.
- Queued `arrow_r` helper returns now import into an owned DuckDB result
  chunk on the recorded main R thread; the waiting worker copies that
  owned vector into callback output instead of having the main thread
  write directly into the callback-owned output vector.
- [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)
  and
  [`rducks_list_udfs()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_list_udfs.md)
  now include `r_side_record` to make detached/missing R-side registry
  metadata explicit. Native per-UDF hot-path counters are updated with
  atomics rather than the process-global runtime registry lock.
- Added
  [`rducks_native_execution_backend()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_native_execution_backend.md)
  to cross-check the native database-scoped execution backend against
  the R-side current/default execution plan.
- The Arrow IPC NNG path defaults to one-time UDF global discovery
  (`ipc_globals = "auto"`) and then broadcasts explicit globals when the
  UDF is registered with the provider pool. This avoids per-chunk
  automatic global discovery while preserving common UDF globals; set
  `ipc_globals = TRUE`, `FALSE`, a character vector, or a named list to
  override the behavior.
- Execution plans now carry a concrete `engine_id` (for example
  `arrow_c_direct_serial`, `arrow_c_direct_main_queue`, or
  `ipc_nng_pool`), and `rducks_as_execution_plan()` accepts the current
  engine-id shortcuts.
- [`rducks_inproc_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_inproc_stats.md)
  now reports main-thread drain attempts, non-empty drain batches, and
  maximum drain batch size in addition to pending/running queue pressure
  and timeout semantics.
- The SQL execution-backend setter now requires the recorded main-thread
  capability carried by Rducks’ R wrapper, and the main-thread token can
  no longer be rebound to a different token after initialization. Manual
  SQL calls with a bare backend string fail instead of mutating runtime
  execution state.
- Dev/test-only SQL probes (`rducks_parallel_range`,
  `rducks_parallel_thread_probe`, `rducks_queue_self_test`, and
  `rducks_thread_is_main`) are now registered only when
  `RDUCKS_DEV_SURFACES=true` is set before extension load. Production
  SQL surfaces keep only the registration, execution, and documented
  statistics helpers.
- Direct `arrow_c` scalar/vectorized execution and the Arrow/R + Arrow
  IPC callback paths are fenced with `R_tryCatchError()` plus
  `R_UnwindProtect()` so unexpected marshalling/allocation errors are
  converted into DuckDB UDF errors without installing a fresh R
  top-level context inside DuckDB callbacks. RIPC cleanup now releases
  preserved task/schema objects and decrements in-flight counters on
  abnormal unwind.
- Arrow C Data result import now copies the temporary imported DuckDB
  vector into the callback-owned output vector before destroying the
  imported chunk, avoiding reliance on reference-vector lifetime
  semantics.
- Added direct native `arrow_c` vectorized UDF support (`RCV`) for
  signatures accepted by the direct `arrow_c` type matrix. Chunk
  arguments are materialized from DuckDB vectors in C, return rows are
  written back through the direct writer, and generated marshalling
  coverage verifies the selected native path. Queued direct `arrow_c`
  scalar and vectorized UDFs now copy input vectors into an owned DuckDB
  data chunk before the request is submitted to the recorded main R
  thread. With supported scalar returns, they then evaluate into an
  owned Arrow C Data result chunk; the waiting worker writes DuckDB
  output from those Arrow buffers without touching `SEXP`s or nanoarrow
  R external pointers. Composite direct returns now use an owned DuckDB
  result chunk filled on the main R thread and copied into callback
  output by the waiting worker. The owned return envelope covers
  primitive, temporal, VARCHAR/BLOB/BIT, DECIMAL, ENUM, UUID,
  HUGEINT/UHUGEINT, and INTERVAL results; the owned DuckDB result-chunk
  path covers direct composite returns.
- Added an internal `%||%` compatibility shim so the package works under
  the lowered R 4.3 dependency floor.
- `arrow_c` is now a direct scalar and vectorized marshalling path.
  Unsupported signatures fail explicitly instead of changing to Arrow/R
  helper marshalling.
- Added
  [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)
  and
  [`rducks_list_udfs()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_list_udfs.md)
  with native per-UDF execution counters so users can inspect
  registration metadata and verify that `arrow_r`/`arrow_c` chunks ran
  through the requested evaluator. Added
  [`rducks_release_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_release_stats.md)
  to inspect process-local counters for preserved R objects queued by
  off-main DuckDB metadata destructors and drained later on the recorded
  main R thread. Added
  [`rducks_runtime_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_runtime_stats.md)
  to inspect native runtime registry and extension-owned connection
  accounting.
- Added an R-universe badge to the README and lowered the package R
  dependency floor to R 4.3.
- Added wasm/webR build detection in `configure`, including the DuckDB
  wasm metadata platform and explicit Emscripten export for the
  extension entrypoint, plus a `Dockerfile.webr-test` helper for local
  rwasm builds and a local browser smoke harness under `scripts/`.
- Added explicit execution-plan helpers
  [`rducks_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_execution_plan.md),
  [`rducks_set_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_set_execution_plan.md),
  and
  [`rducks_current_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_current_execution_plan.md)
  to separate UDF semantics from connection-level
  marshalling/concurrency policy. The `arrow_r + serial` plan is the
  reference implementation; unsupported execution-plan combinations fail
  explicitly through plan validation.
- Removed per-registration evaluator selection from
  [`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md).
  The evaluator is now derived from the active execution plan, so
  conformance tests compare plan-native registrations instead of mixing
  evaluator choices inside a single registration call.
- Added `mode = "vectorized"` for R UDFs that should be called once per
  DuckDB chunk with vector/list-column arguments. The vectorized adapter
  uses the same Arrow C Data/nanoarrow bridge as scalar mode, enforces
  return length, defines default vs special NULL handling, and is
  covered by runtime tests.
- Added an official in-process queued execution API for scalar UDFs:
  [`rducks_enable_inproc()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable_inproc.md),
  [`rducks_disable_inproc()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_disable_inproc.md),
  [`rducks_inproc_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_inproc_stats.md),
  and
  [`rducks_inproc_self_test()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_inproc_self_test.md).
  The backend keeps all R API work on the recorded main R thread and
  uses an extension-owned queue with timeout/error paths rather than a
  package-side pump or hidden progress callback.
- Added native queue diagnostics and tests covering main-thread queue
  draining and scalar/vectorized UDF execution through the queued path.
  [`rducks_inproc_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_inproc_stats.md)
  now reports the configured pending-request timeout and explicitly
  reports that running queued requests cannot be cancelled safely while
  they borrow DuckDB callback storage.
- Split scalar execution and native extension runtime state so UDF
  metadata uses DuckDB C extension bind/init/local-state hooks and
  per-loaded-database runtime entries instead of a singleton connection.
- Initial development scaffold for an R package and DuckDB extension
  bridge for R user-defined functions.
