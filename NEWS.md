# Rducks 0.0.1

- Added an `arrow_ipc + multiprocess_parallel` UDF path using generic `future`
  backends with Arrow IPC task/result payloads. Scalar registrations loop over
  rows inside the worker, vectorized registrations call once per chunk, and the
  queued native path splits submit and collect phases so queued chunk tasks can
  be submitted before grouped result collection. `rducks_explain_udf()` now
  reports queue-pending, RIPC-in-flight, and RIPC collect batch counters for
  diagnosing whether chunks are actually overlapping. Arrow IPC encoding for nanoarrow arrays now uses a native buffer
  writer instead of an R `rawConnection`, avoiding large transient allocations.
  Enum arguments and returns are supported through an explicit Rducks
  enum-storage IPC convention.
- Added an internal `%||%` compatibility shim so the package works under the
  lowered R 4.3 dependency floor.
- Implemented `arrow_c + vectorized` registrations for both `serial` and
  `inproc_concurrent` execution plans. The native evaluator token is `RCV`, and
  `rducks_explain_udf()` reports `arrow_c` counters for these chunk calls.
- Added `rducks_explain_udf()` and `rducks_list_udfs()` with native per-UDF
  execution counters so users can inspect registration metadata and verify that
  `arrow_r`/`arrow_c` chunks ran through the requested evaluator without
  fallback.
- Added an R-universe badge to the README and lowered the package R dependency
  floor to R 4.3.
- Added wasm/webR build detection in `configure`, including the DuckDB wasm
  metadata platform and explicit Emscripten export for the extension entrypoint,
  plus a `Dockerfile.webr-test` helper for local rwasm builds.
- Added explicit execution-plan helpers `rducks_execution_plan()`,
  `rducks_set_execution_plan()`, and `rducks_current_execution_plan()` to
  separate UDF semantics from connection-level marshalling/concurrency policy.
  The `arrow_r + serial` plan is the reference implementation; `arrow_c +
  vectorized` and planned `arrow_ipc + multiprocess_parallel` execution now fail
  explicitly through plan validation rather than silently falling back.
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
- Added native queue diagnostics and tests covering main-lane queue draining and
  scalar UDF execution through the queued path.
- Split scalar execution and native extension runtime state so UDF metadata uses
  DuckDB C extension bind/init/local-state hooks and per-loaded-database runtime
  entries instead of a singleton connection.
- Initial development scaffold for an R package and DuckDB extension bridge for
  R user-defined functions.
