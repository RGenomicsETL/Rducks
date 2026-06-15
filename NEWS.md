# Rducks (development version)

* `transport = "ipc"` now supports dynamic (omitted-`args`) scalar UDFs, matching `transport = "inproc"`. DuckDB resolves the concrete argument types per call site at bind; the native bind carries those resolved types to the worker in an `RDT1` dynamic payload (concrete arg tokens + the Quack chunk), so one registration serves call sites with different argument types. A type the wire codec cannot encode fails cleanly at the first chunk encode.

# Rducks (development): Arrow removal

* BREAKING: `rducks_execution_plan()` now takes `transport = c("inproc", "ipc")`; the `arrow_r`/`arrow_c`/`arrow_ipc` x concurrency axis is gone.
* `transport = "ipc"` (worker-process execution) is restored over the Quack wire codec: the extension encodes each input chunk to wire bytes in pure C, ships it to a worker R process over NNG, and decodes the wire-encoded result back into DuckDB. Worker-process types currently cover fixed-width scalars, VARCHAR/BLOB, DECIMAL, INTERVAL, ENUM, BIT, GEOMETRY, MAP, UNION, and LIST/ARRAY/STRUCT of supported types; VARIANT is rejected at registration until the native bridge covers it.
* nanoarrow is removed from Imports/LinkingTo; the vendored nanoarrow/flatcc trees are deleted from the extension.
* The worker-process data plane uses the Rducks Quack wire codec (DuckDB BinarySerializer DataChunk subset) with self-describing payloads.
* `rducks_with_duckplyr()` (duckplyr bridge) and `rducks_register_table()` (table functions, finite and streaming) are restored on the direct DuckDB-vector path. In-process table scans fill DuckDB output vectors directly from the returned R columns, with no wire serialization.
* `rducks_query_stream()` is restored on the direct path: native DuckDB streaming results are materialized to data-frame batches directly from DuckDB vectors.
* Internal: queued/concurrent scalar-UDF results are now written through an owned `duckdb_data_chunk` for every supported return type.
* Internal: dropped the unused per-call `connection_id` capture, removing four DuckDB client-context entries from the unstable C API surface (no behavior change).
* The Arrow-era vignettes are removed; the README covers current usage, including an `inproc`-vs-`ipc` worker-process benchmark (with optional mori global sharing).

# Rducks 0.1.1

- Improved configure-time CMake discovery for required vendored NNG builds on
  macOS builders by honoring `CMAKE`, using `cmake` from `PATH`, and probing
  CRAN/macbuilder's `/Applications/CMake.app/Contents/bin/cmake` location while
  keeping missing CMake as a hard configuration error.
- Cleaned up macOS source-check diagnostics by removing an unused native
  helper, suppressing private-extension debug-map noise from vendored static
  archives, and making NNG batch-contract tests use local IPC fake workers
  instead of random loopback TCP ports in sandboxed check environments.
- Tightened dynamic-varargs test lifecycle cleanup so extension-owned DuckDB
  connections are closed before in-memory test databases are disconnected.
  Explicit native runtime-connection release now also detaches the runtime from
  the raw DuckDB database handle, preventing stale address aliases during later
  in-process database creation.

# Rducks 0.1.0

- Fixed a Windows R-devel check hang in the dev/test in-process queue
  cancellation coverage. The test previously used R's elapsed-time limit as a
  synthetic interrupt while execution was inside native queue-draining code;
  that interrupt is not delivered reliably on Windows while native code is
  running. Rducks now exercises the same queue cancel-generation cleanup path
  with a deterministic dev-only cancellation diagnostic, verifies that the
  connection and queue remain usable afterward, and keeps pending/running queue
  counters at zero after cancellation.
- Protected the transient evaluator object during native scalar-UDF
  registration so R-devel garbage collection cannot reclaim it before the
  extension preserves it in DuckDB metadata.
- Added first-class `GEOMETRY` and `VARIANT` type descriptors. `GEOMETRY`
  crosses the R boundary as WKB `raw` bytes; `VARIANT` is exposed as DuckDB's
  typed storage struct wrapped by `rducks_variant`, with SQL-side DuckDB
  VARIANT functions remaining the canonical way to construct and inspect
  semantic values. VARIANT scalar-UDF registration requires a DuckDB runtime C
  API that exposes VARIANT logical types.
- Tightened execution-plan and support documentation, clarified aggregate state
  ownership, and expanded tests for IPC, duckplyr, query streams, and
  table-stream cardinality.
- Added dynamic-argument scalar UDF registration: omitting `args` in
  `rducks_register_scalar_udf()` registers a DuckDB varargs `ANY` function while
  keeping the return type explicit. DuckDB now resolves the concrete argument
  types at bind time, and Rducks uses those effective types for scalar and
  vectorized evaluation, including composite, exotic, and special-NULL inputs.
  Added `rducks_with_duckplyr()` and a `with.duckdb_connection()` method that
  register named R helpers and rewrite matching duckplyr calls so stingy
  duckplyr pipelines can stay in DuckDB rather than falling back to dplyr.
- Renamed the scalar-function registration API to
  `rducks_register_scalar_udf()` and clarified terminology across the user
  documentation: DuckDB function kind (scalar UDF, aggregate function, table
  function), Rducks scalar-UDF evaluation mode, and Rducks execution plan are
  distinct concepts.
- Added `rducks_register_aggregate()` for R-backed DuckDB aggregate
  functions. Aggregate state can now be an arbitrary preserved R object rather
  than only serialized `raw` bytes, row-wise callbacks use
  `update(state, ...)` / `combine(left, right)` / `finalize(state)`, optional
  chunk callbacks use `update_chunk(states, group_id, ...)`,
  `combine_chunk(left_states, right_states)`, and `finalize_chunk(states)`,
  default NULL handling skips rows with top-level NULL inputs, and execution is
  explicitly restricted to the recorded calling R thread.
- Added `rducks_register_table()` support for both finite and streaming
  R-backed table functions. The native table-function path infers positional SQL
  argument count from the R function formals, registers those inputs as DuckDB
  `ANY`, converts actual SQL bind values to R values, and calls the R function
  during DuckDB bind on the recorded calling R thread. Finite results infer the
  output schema from a returned data frame/list, while `rducks_table_stream()`
  adds a scan-time `next_batch()` path driven by a bind-time prototype, optional
  cardinality metadata, and projection-aware output copying.
- Added vendored NNG/Mbed TLS source management for the native worker-provider
  foundation. `tools/vendor_nng_mbedtls.R` pins and refreshes the vendored
  sources, source builds statically link a hidden NNG client shim, and dev/test
  SQL diagnostics expose `rducks_nng_version()` and `rducks_nng_self_test()`.
- Added `rducks_query_stream()` as a connection-bound R-side streaming query
  object with explicit `next_batch()`, `close()`, schema/prototype metadata,
  finalizer cleanup, and `rducks_release()` integration. Query streams now use
  DuckDB's native streaming result/data-chunk APIs through a dedicated
  extension-owned query-stream connection, keeping dynamic scalar, table, and
  aggregate registration on the separate runtime connection. Fetched chunks are
  materialized into data-frame batches directly from DuckDB vectors.
- Clarified IPC shared-memory capability metadata and design notes: mori is a
  same-host path for long-lived globals, while built-in backends still report no
  SQL chunk shared-memory handle support.
- The NNG provider path launches local mirai/nanonext worker loops by default,
  supports explicit `ipc_endpoints`, and errors rather than changing to generic
  process backends, same-process execution, or R serialization.
- `rducks_explain_udf()` now reports queue-pending and worker-process (RIPC)
  diagnostic counters for future native provider work.
- Added `rducks_reset_udf_counters()` to reset one UDF's diagnostic counters or
  all native UDF counters in the current database runtime without unregistering
  catalog functions.
- UDF stat field discovery now comes from native `rducks_udf_stat_fields()`;
  the R-side field vector is only a documented compatibility list for sessions
  where that optional native discovery helper is unavailable.
- `rducks_explain_udf()` and `rducks_list_udfs()` now include `r_side_record`
  to make detached/missing R-side scalar-UDF registry metadata explicit. Native
  per-UDF hot-path counters are updated with atomics rather than the
  process-global runtime registry lock.
- Added `rducks_native_execution_backend()` to cross-check the native
  database-scoped execution backend against the R-side current/default execution
  plan.
- The worker-process (ipc) path defaults to one-time scalar-UDF global discovery
  (`ipc_globals = "auto"`) and then broadcasts explicit globals when the scalar
  UDF is registered with the provider pool. This avoids per-chunk automatic global
  discovery while preserving common scalar-UDF globals; set `ipc_globals = TRUE`,
  `FALSE`, a character vector, or a named list to override the behavior.
- Execution plans carry a concrete `engine_id`, and `rducks_as_execution_plan()`
  accepts the current engine-id shortcuts.
- `rducks_inproc_stats()` now reports main-thread drain attempts, non-empty
  drain batches, and maximum drain batch size in addition to pending/running
  queue pressure and timeout semantics.
- The SQL execution-backend setter now requires the recorded main-thread
  capability carried by Rducks' R wrapper, and the main-thread token can no
  longer be rebound to a different token after initialization. Manual SQL calls
  with a bare backend string fail instead of mutating runtime execution state.
- Dev/test-only SQL probes (`rducks_parallel_range`,
  `rducks_parallel_thread_probe`, `rducks_queue_self_test`, and
  `rducks_thread_is_main`) are now registered only when
  `RDUCKS_DEV_SURFACES=true` is set before extension load. Production SQL
  surfaces keep only the registration, execution, and documented statistics
  helpers.
- Scalar-UDF execution and worker-process callback paths are fenced with
  `R_tryCatchError()` plus `R_UnwindProtect()` so unexpected
  marshalling/allocation errors are converted into DuckDB UDF errors without
  installing a fresh R top-level context inside DuckDB callbacks. RIPC cleanup
  now releases the worker client pool and decrements in-flight counters on
  abnormal unwind.
- Added direct native vectorized UDF support (`RCV`). Chunk arguments are
  materialized from DuckDB vectors in C, return rows are written back through the
  direct writer, and generated marshalling coverage verifies the selected native
  path. Queued row-wise and vectorized scalar UDFs copy input vectors into an
  owned DuckDB data chunk before the request is submitted to the recorded main R
  thread, then evaluate into an owned DuckDB result chunk that the waiting worker
  copies into callback output. The owned return envelope covers primitive,
  temporal, VARCHAR/BLOB/BIT, DECIMAL, ENUM, UUID, HUGEINT/UHUGEINT, INTERVAL,
  and composite results.
- Added an internal `%||%` compatibility shim so the package works under the
  lowered R 4.3 dependency floor.
- Scalar-UDF evaluation uses direct DuckDB-vector marshalling for row-wise and
  vectorized modes; unsupported signatures fail explicitly.
- Added `rducks_explain_udf()` and `rducks_list_udfs()` with native per-UDF
  execution counters so users can inspect registration metadata and verify that
  chunks ran through the requested evaluator. Added
  `rducks_release_stats()` to inspect process-local counters for
  preserved R objects queued by off-main DuckDB metadata destructors and drained
  later on the recorded main R thread. Added `rducks_runtime_stats()` to inspect
  native runtime registry and extension-owned connection accounting.
- Added an R-universe badge to the README and lowered the package R dependency
  floor to R 4.3.
- Added wasm/webR build detection in `configure`, including the DuckDB wasm
  metadata platform and explicit Emscripten export for the extension entrypoint,
  plus a `Dockerfile.webr-test` helper for local rwasm builds and a local browser
  smoke harness under `scripts/`.
- Added explicit execution-plan helpers `rducks_execution_plan()`,
  `rducks_set_execution_plan()`, and `rducks_current_execution_plan()` to
  separate scalar-UDF semantics from connection-level marshalling/concurrency policy.
  Unsupported execution-plan combinations fail explicitly through plan validation.
- Removed per-registration evaluator selection from `rducks_register_scalar_udf()`. The
  evaluator is now derived from the active execution plan, so conformance tests
  compare plan-native registrations instead of mixing evaluator choices inside a
  single registration call.
- Added `mode = "vectorized"` for DuckDB scalar UDFs whose backing R function
  should be called once per DuckDB chunk with vector/list-column arguments. The
  vectorized adapter shares the scalar row-wise marshalling path, enforces return
  length, defines default vs special NULL handling, and is covered by runtime
  tests.
- Added an official in-process queued execution API for scalar UDFs:
  `rducks_enable_inproc()`, `rducks_disable_inproc()`,
  `rducks_inproc_stats()`, and `rducks_inproc_self_test()`. The backend keeps
  all R API work on the recorded main R thread and uses an extension-owned queue
  with timeout/error paths rather than a package-side pump or hidden progress
  callback.
- Added native queue diagnostics and tests covering main-thread queue draining
  and scalar-UDF execution through the queued path. `rducks_inproc_stats()`
  now reports the configured pending-request timeout and explicitly reports that running
  queued requests cannot be cancelled safely while they borrow DuckDB callback
  storage.
- Split scalar execution and native extension runtime state so UDF metadata uses
  DuckDB C extension bind/init/local-state hooks and per-loaded-database runtime
  entries instead of a singleton connection.
- Initial development scaffold for an R package and DuckDB extension bridge for
  R user-defined functions.
