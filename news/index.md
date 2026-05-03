# Changelog

## Rducks 0.0.0.9000

- Added
  [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)
  with native per-UDF execution counters so users can inspect
  registration metadata and verify that `arrow_r`/`arrow_c` chunks ran
  through the requested evaluator without fallback.
- Added an R-universe badge to the README and lowered the package R
  dependency floor to R 4.3.
- Added wasm/webR build detection in `configure`, including the DuckDB
  wasm metadata platform and explicit Emscripten export for the
  extension entrypoint, plus a `Dockerfile.webr-test` helper for local
  rwasm builds.
- Added explicit execution-plan helpers
  [`rducks_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_execution_plan.md),
  [`rducks_set_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_set_execution_plan.md),
  and
  [`rducks_current_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_current_execution_plan.md)
  to separate UDF semantics from connection-level
  marshalling/concurrency policy. The `arrow_r + serial` plan is the
  reference implementation; `arrow_c + vectorized` and planned
  `arrow_ipc + multiprocess_parallel` execution now fail explicitly
  through plan validation rather than silently falling back.
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
- Added native queue diagnostics and tests covering main-lane queue
  draining and scalar UDF execution through the queued path.
- Split scalar execution and native extension runtime state so UDF
  metadata uses DuckDB C extension bind/init/local-state hooks and
  per-loaded-database runtime entries instead of a singleton connection.
- Initial development scaffold for an R package and DuckDB extension
  bridge for R user-defined functions.
