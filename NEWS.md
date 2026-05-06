# Rducks 0.0.1

- Added an `arrow_ipc + multiprocess_parallel` UDF path using generic `future`
  backends with Arrow IPC task/result payloads. Scalar registrations loop over
  rows inside the worker, vectorized registrations call once per chunk, and the
  queued native path splits submit and collect phases so queued chunk tasks can
  be submitted before grouped result collection. Main-thread RIPC callbacks now
  cooperatively drain queued worker callbacks into the same submit/collect wave,
  avoiding the single-request timeout path for parallel DuckDB UDF execution.
  `rducks_explain_udf()` now reports queue-pending, RIPC-in-flight, and RIPC submit/collect wave counters
  for diagnosing whether chunks are actually overlapping. Arrow IPC encoding for nanoarrow arrays now uses a native buffer
  writer instead of an R `rawConnection`, avoiding large transient allocations.
  Enum arguments and returns are supported through an explicit Rducks
  enum-storage IPC convention.
- Arrow C Data result import now copies the temporary imported DuckDB vector
  into the callback-owned output vector before destroying the imported chunk,
  avoiding reliance on reference-vector lifetime semantics.
- Added direct native `arrow_c` vectorized UDF support (`RCV`) for signatures
  accepted by the direct `arrow_c` type matrix. Chunk arguments are materialized
  from DuckDB vectors in C, return rows are written back through the direct
  writer, and generated marshalling coverage verifies the path does not fall
  back to Arrow/R helpers.
- Added an internal `%||%` compatibility shim so the package works under the
  lowered R 4.3 dependency floor.
- `arrow_c` is now a direct scalar and vectorized marshalling path. Unsupported
  signatures fail explicitly instead of falling back to Arrow/R helper
  marshalling.
- Added `rducks_explain_udf()` and `rducks_list_udfs()` with native per-UDF
  execution counters so users can inspect registration metadata and verify that
  `arrow_r`/`arrow_c` chunks ran through the requested evaluator without
  fallback. Added `rducks_release_stats()` to inspect process-local counters for
  preserved R objects queued by off-main DuckDB metadata destructors and drained
  later on the recorded main R thread. Added `rducks_runtime_stats()` to inspect
  native runtime registry and extension-owned connection accounting.
- Added an R-universe badge to the README and lowered the package R dependency
  floor to R 4.3.
- Added wasm/webR build detection in `configure`, including the DuckDB wasm
  metadata platform and explicit Emscripten export for the extension entrypoint,
  plus a `Dockerfile.webr-test` helper for local rwasm builds.
- Added explicit execution-plan helpers `rducks_execution_plan()`,
  `rducks_set_execution_plan()`, and `rducks_current_execution_plan()` to
  separate UDF semantics from connection-level marshalling/concurrency policy.
  The `arrow_r + serial` plan is the reference implementation; unsupported
  execution-plan combinations fail explicitly through plan validation rather than
  silently falling back.
- Removed per-registration evaluator selection from `rducks_register()`. The
  evaluator is now derived from the active execution plan, so conformance tests
  compare plan-native registrations instead of mixing evaluator choices inside a
  single registration call.
- Added `mode = "vectorized"` for R UDFs that should be called once per DuckDB
  chunk with vector/list-column arguments. The vectorized adapter uses the same
  Arrow C Data/nanoarrow bridge as scalar mode, enforces return length, defines
  default vs special NULL handling, and is covered by runtime tests.
- Added an official in-process queued execution API for scalar UDFs:
  `rducks_enable_inproc()`, `rducks_disable_inproc()`,
  `rducks_inproc_stats()`, and `rducks_inproc_self_test()`. The backend keeps
  all R API work on the recorded main R thread and uses an extension-owned queue
  with timeout/error paths rather than a package-side pump or hidden progress
  callback.
- Added native queue diagnostics and tests covering main-thread queue draining
  and scalar/vectorized UDF execution through the queued path. `rducks_inproc_stats()`
  now reports the configured pending-request timeout and explicitly reports that running
  queued requests cannot be cancelled safely while they borrow DuckDB callback
  storage.
- Split scalar execution and native extension runtime state so UDF metadata uses
  DuckDB C extension bind/init/local-state hooks and per-loaded-database runtime
  entries instead of a singleton connection.
- Initial development scaffold for an R package and DuckDB extension bridge for
  R user-defined functions.
