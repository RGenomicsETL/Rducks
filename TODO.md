# Rducks TODO

This file is development-facing. Keep user-facing changes in `NEWS.md` and
README/docs. Do not use this file as a historical changelog; it should describe
what still needs doing.

## Current facts

- Current pushed baseline when this file was refreshed: `4ac8ba2 Document
  null-argument UDFs and refresh TODO`.
- Local validation at that baseline:
  - `R CMD INSTALL .` OK
  - `make test` OK: 530 tinytest results
  - `README.Rmd` rendered to `README.md`
- GitHub Actions at that baseline:
  - `R-CMD-check.yaml`: success, including R 4.3
  - `Generated marshalling matrix`: success, release and R 4.3
  - `pkgdown.yaml`: success
- R-universe at that baseline:
  - `RemoteSha = 4ac8ba2079dc13e91c511246fdd9cad4defb654f`
  - `_status = success`
  - Linux/macOS/Windows binaries success
  - wasm binary success

## Non-negotiable constraints

- Use DuckDB C API / C extension API only; no DuckDB C++ API in the extension.
- Do not touch duckdb-r internals such as `con@conn_ref`.
- Keep R API work on the recorded main R thread for same-process execution.
- Destructors/finalizers that may run off the main R thread must not call R API.
- No hidden fallback:
  - no `arrow_c -> arrow_r`
  - no `arrow_ipc -> serialize()`
  - no `multiprocess_parallel -> in-process`
  - no vectorized chunk call -> scalar row loop
- Same-process concurrency is a liveness/scheduling feature, not a speed promise.
- Keep `arrow_lossless_conversion=true` documented: it affects DuckDB-to-Arrow
  conversion at the Rducks boundary, not stored DuckDB values or SQL semantics.

## Implemented execution matrix to preserve

| Plan | Scalar | Vectorized | Notes |
| --- | --- | --- | --- |
| `arrow_r + serial` | implemented | implemented | semantic reference |
| `arrow_r + inproc_concurrent` | implemented | implemented | queued same-process callbacks; R API work stays on the recorded main R thread |
| `arrow_c + serial` | implemented | implemented | native scalar evaluator `RC`; vectorized evaluator `RCV` |
| `arrow_c + inproc_concurrent` | implemented | implemented | queued same-process callbacks with `arrow_c` marshalling |
| `arrow_ipc + multiprocess_parallel` | implemented | implemented | Future-backed Arrow IPC path, evaluator `RIPC` |

Implemented behavior to preserve:

- The active plan at `rducks_register()` chooses the native evaluator stored in
  DuckDB UDF metadata (`R`, `RC`, `RCV`, or `RIPC`). Later plan changes alter the
  runtime concurrency backend, but do not retarget already-registered UDF
  marshalling.
- Zero-argument scalar UDFs use `args = NULL`.
- Zero-argument vectorized UDFs are not exposed.
- `side_effects = TRUE` marks the DuckDB scalar function volatile; it does not
  alter R-thread or queue semantics.

## Decisions needed

1. **Connection object model for R-side state.**
   - Problem: R-side stores still key by SEXP address via `rducks_connection_key()`.
     Freed R object addresses can be reused.
   - Decision: should `rducks_enable(con)` return a `rducks_connection` subclass
     that users must assign (`con <- rducks_enable(con)`), or should we keep
     returning the original `duckdb_connection` invisibly and attach an Rducks
     attribute/guard?
   - My recommendation: use a returned subclass/wrapper if we want a reliable
     `dbDisconnect()` method; use an attribute only if preserving the current
     API shape is more important than automatic cleanup.

2. **Runtime release API shape.**
   - Problem: DuckDB has no database/connection close hook in the C extension
     API. The extension-owned connection can pin the runtime.
   - Decision: should `rducks_release(con)` be required before `dbDisconnect()`,
     or should a `rducks_connection` `dbDisconnect()` method make it automatic?
   - Non-decision already made for now: native cleanup may leak preserved R
     closures rather than calling R API off the main R thread.

3. **Duplicate registration semantics.**
   - Decide whether duplicate `name`/signature registration errors, overwrites,
     or creates overloads.
   - This blocks clear `rducks_unregister()` semantics.

4. **Registration-time vs query-time marshalling contract.**
   - Current implementation is registration-time marshalling.
   - Decision: document this as public semantics now, or redesign for query-time
     marshalling dispatch.
   - My recommendation: document registration-time marshalling for now.

5. **`rducks_inproc_stats()` scope.**
   - Current function exposes runtime-wide `submitted`, `executed`, `timeouts`.
   - Per-UDF pressure/batching counters are available through
     `rducks_explain_udf()`.
   - Decide whether to keep `rducks_inproc_stats()` intentionally minimal or add
     runtime-wide pending/max counters.

## P0: connection identity and lifecycle

- [ ] Replace SEXP-address keying for R-side connection state.
  - Target: a stable Rducks runtime token from the native extension, for example
    `SELECT rducks_connection_token()` or a `.Call` equivalent.
  - Token should be Rducks-owned and generation-safe, not just a raw R object
    address.
  - Use it for `.rducks_state$connection_plans` and
    `.rducks_state$registrations`.
  - Acceptance: repeated connect/register/disconnect/reconnect loops cannot make
    a new connection see stale plans or stale UDF metadata.

- [ ] Implement idempotent runtime release.
  - Target API: `rducks_release(con)`.
  - Native cleanup: invalidate/remove runtime entry, drain/reset queue state,
    disconnect extension-owned DuckDB connection, detach UDF registry
    bookkeeping.
  - R cleanup: remove token-keyed plan and registration stores.
  - Must not call DBI/SQL from finalizers.
  - Must not call R API from off-main native destructors.

- [ ] Integrate release with `dbDisconnect()` if the connection object model
  permits it.
  - If subclass/wrapper is chosen, implement a `dbDisconnect()` method that calls
    `rducks_release()` before delegating to duckdb-r.
  - If plain `duckdb_connection` is retained, document explicit release and add
    tests showing idempotency.

- [ ] Add repeated lifecycle tests.
  - Include repeated `:memory:` databases, extension reloads, UDF registration,
    explicit release, and DBI disconnect.
  - Assert R-side stores do not expose stale plans or UDF metadata.

## P1: correctness hardening

- [ ] Fix queued request waits once a request is `RUNNING`.
  - Current timeout only applies while a request is `PENDING`.
  - `rducks_queue_submit_scalar_via_worker_on_main()` can still end in an
    unbounded `pthread_join()` / Windows wait.

- [ ] Add stress tests for no-deadlock behavior.
  - Repeated queued UDF calls with multiple DuckDB threads should complete or
    fail with documented timeout text, never hang.

- [ ] Add a main-thread release queue for preserved R objects, or explicitly
  document the leak-until-session-end policy.
  - Current native destructors avoid unsafe `R_ReleaseObject()` off-main.

- [ ] Extend no-fallback assertions to scalar generated matrix cases where
  native counters are meaningful.
  - Vectorized generated cases already assert `arrow_r`/`arrow_c` counter
    movement.

- [ ] Add focused tests for every `arrow_c` fallback-to-`arrow_r` risk.
  - Acceptance: `rducks_explain_udf()` shows `arrow_c_chunks > 0` and
    `arrow_r_chunks == 0` for supported `arrow_c` cases.

- [ ] Handle partial failures in `rducks_set_execution_plan()`.
  - Current risk: thread settings may change before native backend setup fails,
    while the R-side plan cache remains old.
  - Either roll back thread settings or document partial application.

- [ ] Defensively clear Arrow C Data release callbacks on conversion failure.

- [ ] Re-audit Arrow validity handling.
  - Current concern: `rducks_arrow_validity()` relies on nanoarrow/DuckDB
    validity-buffer behavior that should be made explicit or guarded.

- [ ] Audit remaining `Rf_*` longjmp paths.
  - Use `R_alloc()` or `R_UnwindProtect()` where heap state would otherwise leak
    across `Rf_error()`.

- [ ] Add GC/lifetime tests.
  - Drop R registration objects, run `gc()`, then call DuckDB UDFs.
  - Close/release connections after registrations and confirm no crashes or
    stale R-side metadata.

## P2: observability and diagnostics

- [ ] Decide and implement the `rducks_inproc_stats()` scope decision.
  - If expanded, include runtime-wide pending current/max counters.
  - If kept minimal, docs should explicitly point users to per-UDF counters in
    `rducks_explain_udf()`.

- [ ] Add counter reset support.
  - Reset one UDF or all UDF counters without unregistering the UDF.

- [ ] Expose native current-backend diagnostics.
  - R-side `rducks_current_execution_plan()` should be cross-checkable against
    native backend state.

- [ ] Mark or skip missing R-side registration records.
  - Current `rducks_explain_udf_row()` can return rows with `NA` metadata when
    the R-side record is absent.
  - Options: add `rducks_managed = TRUE/FALSE`, or make `rducks_list_udfs()` omit
    rows without current-session Rducks metadata.

- [ ] Generate/discover native UDF stat fields instead of mirroring names by
  hand in R and C.

## P2/P3: Arrow IPC and worker execution

- [ ] Fix cooperative RIPC counter under-reporting.
  - Runtime-wide `submitted/executed` can be lower than per-UDF queued chunk
    counts on cooperative paths.

- [ ] Reduce Arrow IPC/Future overhead for cheap UDFs without hidden fallback.

- [ ] Improve batching beyond small waves for typical DuckDB physical scans.

- [ ] Specify a persistent worker/request envelope if generic `future` is not
  enough.
  - Include UDF id/name, signature, mode, null/error semantics, chunk sequence,
    timeout, cancellation token, and schema metadata.
  - Hot data path remains Arrow IPC bytes; no R `serialize()` / `unserialize()`
    fallback for chunk payloads.

- [ ] Decide worker transport beyond generic `future` if needed.
  - Do not link against uninstalled `nanonext.so` internals.

- [ ] Implement persistent worker startup/shutdown, backpressure, cancellation,
  and error propagation if generic `future` is not enough.

## P3: owned same-process chunk boundaries

The current in-process queue is synchronous and borrows DuckDB input/output
pointers only for the duration of a scalar UDF callback. That is acceptable for
current callbacks, but not for an asynchronous same-process design.

- [ ] Implement owned input snapshots for worker-originating chunk requests.
- [ ] Implement owned result payloads plus safe writeback.
- [ ] Split `arrow_c` into worker-safe native phases and recorded-main-R-thread
  phases.

## Wasm / webR

- [x] wasm builds on R-universe for the current baseline.
- [ ] Add a webR runtime smoke test, not just a build test.
  - Install the built `.tgz` in webR and run at least package load, native helper
    calls, and a minimal DuckDB extension load if supported.
- [ ] Document wasm support level.
  - Clarify whether Rducks on wasm is build-only, package-load smoke tested, or
    full DuckDB-extension runtime tested.

## Documentation backlog

- [x] README documents `arrow_lossless_conversion=true`.
- [x] README quick start shows a zero-argument scalar UDF with `args = NULL`.
- [x] README in-process queue example uses a DuckDB table scan with
  `threads = 4, external_threads = 1`, reports main-thread vs worker-thread
  probe rows, and states that speedup should not be inferred.
- [x] README uses explicit main-thread / worker-thread wording.

- [ ] Update `docs/EXECUTION_PLANS.md`.
  - Include implemented matrix, no-fallback principle, registration-time
    marshalling behavior, `arrow_lossless_conversion=true`, and
    `rducks_explain_udf()` counters.
  - Note: `docs/` is ignored; use `git add -f docs/...` for files that should be
    committed.

- [ ] Keep roxygen/Rd wording aligned with README.
  - Run `make rd` after roxygen changes.

- [ ] Publish an explicit type/mode/plan support table.
  - Include scalar/vectorized support, `arrow_r`/`arrow_c`, NULL handling, and
    copy/borrow expectations.

- [ ] Clarify ownership/lifetime semantics.
  - Preserved R functions, per-connection/runtime registry, external pointer and
    nanoarrow object lifetime, and limitations around off-main destruction.

## Release hygiene

- Keep `NEWS.md` user-facing; do not mention internal agent instructions.
- Do not manually edit generated `.Rd` files; update roxygen comments and run
  `make rd`.
- Before release-like pushes, run:

  ```sh
  make install
  make test
  Rscript tools/run_generated_marshalling_matrix.R
  make check
  ```

- Remove generated artifacts before committing:
  - `Rducks_*.tar.gz`
  - `Rducks_*.tgz`
  - `Rducks.Rcheck/`
  - `inst/rducks_extension/build/`
