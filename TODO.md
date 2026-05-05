# Rducks TODO

This file is development-facing. Keep user-facing changes in `NEWS.md`
and README/docs. Do not use this file as a historical changelog; it
should describe what still needs doing.

## Current facts

- Current pushed baseline when this file was refreshed:
  `4ac8ba2 Document null-argument UDFs and refresh TODO`.
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

- Use DuckDB C API / C extension API only; no DuckDB C++ API in the
  extension.
- Do not touch duckdb-r internals such as `con@conn_ref`.
- Keep R API work on the recorded main R thread for same-process
  execution.
- Destructors/finalizers that may run off the main R thread must not
  call R API.
- No hidden fallback:
  - no `arrow_c -> arrow_r`
  - no `arrow_ipc -> serialize()`
  - no `multiprocess_parallel -> in-process`
  - no vectorized chunk call -\> scalar row loop
- Same-process concurrency is a liveness/scheduling feature, not a speed
  promise.
- Keep `arrow_lossless_conversion=true` documented: it affects
  DuckDB-to-Arrow conversion at the Rducks boundary, not stored DuckDB
  values or SQL semantics.

## Implemented execution matrix to preserve

| Plan | Scalar | Vectorized | Notes |
|----|----|----|----|
| `arrow_r + serial` | implemented | implemented | semantic reference |
| `arrow_r + inproc_concurrent` | implemented | implemented | queued same-process callbacks; R API work stays on the recorded main R thread |
| `arrow_c + serial` | implemented | implemented | native scalar evaluator `RC`; vectorized evaluator `RCV` |
| `arrow_c + inproc_concurrent` | implemented | implemented | queued same-process callbacks with `arrow_c` marshalling |
| `arrow_ipc + multiprocess_parallel` | implemented | implemented | Future-backed Arrow IPC path, evaluator `RIPC` |

Implemented behavior to preserve:

- The active plan at
  [`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md)
  chooses the native evaluator stored in DuckDB UDF metadata (`R`, `RC`,
  `RCV`, or `RIPC`). Later plan changes alter the runtime concurrency
  backend, but do not retarget already-registered UDF marshalling.
- Zero-argument scalar UDFs use `args = NULL`.
- Zero-argument vectorized UDFs are not exposed.
- `side_effects = TRUE` marks the DuckDB scalar function volatile; it
  does not alter R-thread or queue semantics.

## Empirical notes from connection-object checks

Run with `lobstr` in this session:

- `duckdb_connection` is an S4 object (`typeof(con) == "S4"`), not an
  environment (`is.environment(con) == FALSE`). It contains slots
  including `conn_ref`, but the R wrapper itself follows ordinary
  copy-on-modify behavior.
- Setting an attribute on `con` inside a helper function changed the
  helper’s local copy, not the caller’s object. Therefore a hidden
  attribute/guard or S4 subclass only works if the user keeps the
  returned object, e.g. `con <- rducks_enable(con)`.
- Calling `rducks_enable(con)` without assignment did not change the R
  wrapper address or attributes; it only changed DuckDB/Rducks state
  reachable through the external pointer and package stores.
- Opening several independent `:memory:` databases in one R session
  produced distinct live SEXP keys, but DuckDB `current_connection_id()`
  was the same for each independent database instance. Two connections
  from the same duckdb driver/database produced different
  `current_connection_id()` values. So a DuckDB connection id is useful
  within a database instance but is not a global R-side connection key
  by itself.
- duckdb-r registers
  `reg.finalizer(conn@conn_ref, onexit = TRUE, rapi_disconnect)` when
  connecting. Therefore the DuckDB connection is disconnected by
  GC/session-exit finalization when `conn@conn_ref` becomes unreachable,
  even if users never call
  [`DBI::dbDisconnect()`](https://dbi.r-dbi.org/reference/dbDisconnect.html).
- S4 class extension does not itself create a finalizer. R finalizers
  are only for environments and external pointers.
- Current R weak references can only use reference objects as keys
  (`NILSXP`, `ENVSXP`, `EXTPTRSXP`, or byte-code objects), not the S4
  `duckdb_connection` wrapper itself. A no-subclass GC cleanup path
  therefore needs either a weak reference/finalizer keyed by duckdb-r’s
  `conn_ref` external pointer, or an assigned Rducks-owned guard
  environment/externalptr.
- A small C probe showed the current R runtime finalizes independently
  unreachable external pointers in reverse registration order, so an
  Rducks guard external pointer registered after duckdb-r’s `conn_ref`
  finalizer can empirically run first. R’s
  [`reg.finalizer()`](https://rdrr.io/r/base/reg.finalizer.html)
  documentation does not promise this ordering, so this must not be the
  primary lifecycle guarantee. Cleanup must be idempotent and must not
  depend on whether duckdb-r’s disconnect finalizer has already run.

## Decisions needed

1.  **Connection object model for R-side state.**
    - Problem: R-side stores still key by SEXP address via
      `rducks_connection_key()`. Freed R object addresses can be reused.
    - Empirical result: S4 `duckdb_connection` wrappers are not
      environments and are not mutated in the caller by assigning
      attributes inside
      [`rducks_enable()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable.md)
      unless the modified object is returned and assigned.
    - Refined direction: no S4 subclass is needed merely to clear Rducks
      state when the DuckDB connection external pointer is collected. A
      C weakref/ finalizer keyed by `conn_ref` can remove token-keyed
      registries when the connection becomes unreachable.
    - Remaining decision: are we willing to use read-only access to
      duckdb-r’s `conn_ref` slot for this lifecycle anchor? If not, the
      alternative is an Rducks-owned guard object, which requires
      `con <- rducks_enable(con)`.
    - A subclass/wrapper is only needed if we want to intercept explicit
      `DBI::dbDisconnect(con)` and run Rducks cleanup immediately before
      delegating to duckdb-r.
2.  **Runtime token contents.**
    - Problem: DuckDB `current_connection_id()` is not globally unique
      across independent database instances; raw wrapper addresses can
      be reused.
    - Decision: define a native Rducks token such as
      `(runtime_id, generation)`. It may include DuckDB
      database/connection details for diagnostics, but the unique part
      should be Rducks-owned and monotonic within the process.
3.  **Runtime release API shape and finalizer ordering.**
    - Problem: DuckDB has no database/connection close hook in the C
      extension API. The extension-owned connection can pin the runtime.
    - GC path: key Rducks cleanup to collection of the DuckDB connection
      external pointer, clear token-keyed R stores, and call a native
      idempotent release path that does not require a live DuckDB
      connection.
    - Explicit disconnect caveat: if users call `DBI::dbDisconnect(con)`
      but keep `con` referenced, a weakref/finalizer will not run until
      `con@conn_ref` becomes unreachable. A subclass/wrapper or explicit
      `rducks_release(con)` is still needed for deterministic cleanup at
      disconnect time.
    - Cleanup must not rely on finalizer ordering relative to duckdb-r’s
      own `conn_ref` finalizer.
    - Non-decision already made for now: native cleanup may leak
      preserved R closures rather than calling R API off the main R
      thread.
4.  **Duplicate registration semantics.**
    - Decide whether duplicate `name`/signature registration errors,
      overwrites, or creates overloads.
    - This blocks clear `rducks_unregister()` semantics.
5.  **Registration-time vs query-time marshalling contract.**
    - Current implementation is registration-time marshalling.
    - Decision: document this as public semantics now, or redesign for
      query-time marshalling dispatch.
    - My recommendation: document registration-time marshalling for now.
6.  **[`rducks_inproc_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_inproc_stats.md)
    scope.**
    - Current function exposes runtime-wide `submitted`, `executed`,
      `timeouts`.
    - Per-UDF pressure/batching counters are available through
      [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md).
    - Decide whether to keep
      [`rducks_inproc_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_inproc_stats.md)
      intentionally minimal or add runtime-wide pending/max counters.

## P0: connection identity and lifecycle

Replace SEXP-address keying for R-side connection state.

- Target: a stable Rducks runtime token from the native extension, for
  example `SELECT rducks_connection_token()` or a `.Call` equivalent.
- Token should be Rducks-owned and generation-safe,
  e.g. `(runtime_id, generation)`, not just a raw R object address or
  DuckDB connection id.
- Use it for `.rducks_state$connection_plans` and
  `.rducks_state$registrations`.
- Add a weakref/finalizer lifecycle anchor keyed by the DuckDB
  connection external pointer (`conn_ref`) or by an assigned
  Rducks-owned guard object. On finalization, remove token-keyed R-side
  stores and call idempotent native runtime release.
- If the token/lifecycle anchor is stored on the R connection wrapper
  rather than keyed to `conn_ref`, the enabled connection object must be
  returned and assigned by the caller.
- Acceptance: repeated connect/register/disconnect/reconnect loops
  cannot make a new connection see stale plans or stale UDF metadata.

Implement idempotent runtime release.

- Target API: `rducks_release(con)`.
- Native cleanup: invalidate/remove runtime entry, drain/reset queue
  state, disconnect extension-owned DuckDB connection, detach UDF
  registry bookkeeping.
- R cleanup: remove token-keyed plan and registration stores.
- Must not call DBI/SQL from finalizers.
- Must not call R API from off-main native destructors.

Integrate release with `dbDisconnect()` if the connection object model
permits it.

- If subclass/wrapper is chosen, implement a `dbDisconnect()` method
  that calls `rducks_release()` before delegating to duckdb-r.
- If plain `duckdb_connection` is retained, document explicit release
  and add tests showing idempotency.

Add repeated lifecycle tests.

- Include repeated `:memory:` databases, extension reloads, UDF
  registration, explicit release, and DBI disconnect.
- Assert R-side stores do not expose stale plans or UDF metadata.

## P1: correctness hardening

Fix queued request waits once a request is `RUNNING`.

- Current timeout only applies while a request is `PENDING`.
- `rducks_queue_submit_scalar_via_worker_on_main()` can still end in an
  unbounded `pthread_join()` / Windows wait.

Add stress tests for no-deadlock behavior.

- Repeated queued UDF calls with multiple DuckDB threads should complete
  or fail with documented timeout text, never hang.

Add a main-thread release queue for preserved R objects, or explicitly
document the leak-until-session-end policy.

- Current native destructors avoid unsafe `R_ReleaseObject()` off-main.

Extend no-fallback assertions to scalar generated matrix cases where
native counters are meaningful.

- Vectorized generated cases already assert `arrow_r`/`arrow_c` counter
  movement.

Add focused tests for every `arrow_c` fallback-to-`arrow_r` risk.

- Acceptance:
  [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)
  shows `arrow_c_chunks > 0` and `arrow_r_chunks == 0` for supported
  `arrow_c` cases.

Handle partial failures in
[`rducks_set_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_set_execution_plan.md).

- Current risk: thread settings may change before native backend setup
  fails, while the R-side plan cache remains old.
- Either roll back thread settings or document partial application.

Defensively clear Arrow C Data release callbacks on conversion failure.

Re-audit Arrow validity handling.

- Current concern: `rducks_arrow_validity()` relies on nanoarrow/DuckDB
  validity-buffer behavior that should be made explicit or guarded.

Audit remaining `Rf_*` longjmp paths.

- Use `R_alloc()` or `R_UnwindProtect()` where heap state would
  otherwise leak across `Rf_error()`.

Add GC/lifetime tests.

- Drop R registration objects, run
  [`gc()`](https://rdrr.io/r/base/gc.html), then call DuckDB UDFs.
- Close/release connections after registrations and confirm no crashes
  or stale R-side metadata.

## P2: observability and diagnostics

Decide and implement the
[`rducks_inproc_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_inproc_stats.md)
scope decision.

- If expanded, include runtime-wide pending current/max counters.
- If kept minimal, docs should explicitly point users to per-UDF
  counters in
  [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md).

Add counter reset support.

- Reset one UDF or all UDF counters without unregistering the UDF.

Expose native current-backend diagnostics.

- R-side
  [`rducks_current_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_current_execution_plan.md)
  should be cross-checkable against native backend state.

Mark or skip missing R-side registration records.

- Current `rducks_explain_udf_row()` can return rows with `NA` metadata
  when the R-side record is absent.
- Options: add `rducks_managed = TRUE/FALSE`, or make
  [`rducks_list_udfs()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_list_udfs.md)
  omit rows without current-session Rducks metadata.

Generate/discover native UDF stat fields instead of mirroring names by
hand in R and C.

## P2/P3: Arrow IPC and worker execution

Fix cooperative RIPC counter under-reporting.

- Runtime-wide `submitted/executed` can be lower than per-UDF queued
  chunk counts on cooperative paths.

Reduce Arrow IPC/Future overhead for cheap UDFs without hidden fallback.

Improve batching beyond small waves for typical DuckDB physical scans.

Specify a persistent worker/request envelope if generic `future` is not
enough.

- Include UDF id/name, signature, mode, null/error semantics, chunk
  sequence, timeout, cancellation token, and schema metadata.
- Hot data path remains Arrow IPC bytes; no R
  [`serialize()`](https://rdrr.io/r/base/serialize.html) /
  [`unserialize()`](https://rdrr.io/r/base/serialize.html) fallback for
  chunk payloads.

Decide worker transport beyond generic `future` if needed.

- Do not link against uninstalled `nanonext.so` internals.

Implement persistent worker startup/shutdown, backpressure,
cancellation, and error propagation if generic `future` is not enough.

## P3: owned same-process chunk boundaries

The current in-process queue is synchronous and borrows DuckDB
input/output pointers only for the duration of a scalar UDF callback.
That is acceptable for current callbacks, but not for an asynchronous
same-process design.

Implement owned input snapshots for worker-originating chunk requests.

Implement owned result payloads plus safe writeback.

Split `arrow_c` into worker-safe native phases and
recorded-main-R-thread phases.

## Wasm / webR

wasm builds on R-universe for the current baseline.

Add a webR runtime smoke test, not just a build test.

- Install the built `.tgz` in webR and run at least package load, native
  helper calls, and a minimal DuckDB extension load if supported.

Document wasm support level.

- Clarify whether Rducks on wasm is build-only, package-load smoke
  tested, or full DuckDB-extension runtime tested.

## Documentation backlog

README documents `arrow_lossless_conversion=true`.

README quick start shows a zero-argument scalar UDF with `args = NULL`.

README in-process queue example uses a DuckDB table scan with
`threads = 4, external_threads = 1`, reports main-thread vs
worker-thread probe rows, and states that speedup should not be
inferred.

README uses explicit main-thread / worker-thread wording.

Update `docs/EXECUTION_PLANS.md`.

- Include implemented matrix, no-fallback principle, registration-time
  marshalling behavior, `arrow_lossless_conversion=true`, and
  [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)
  counters.
- Note: `docs/` is ignored; use `git add -f docs/...` for files that
  should be committed.

Keep roxygen/Rd wording aligned with README.

- Run `make rd` after roxygen changes.

Publish an explicit type/mode/plan support table.

- Include scalar/vectorized support, `arrow_r`/`arrow_c`, NULL handling,
  and copy/borrow expectations.

Clarify ownership/lifetime semantics.

- Preserved R functions, per-connection/runtime registry, external
  pointer and nanoarrow object lifetime, and limitations around off-main
  destruction.

## Release hygiene

- Keep `NEWS.md` user-facing; do not mention internal agent
  instructions.

- Do not manually edit generated `.Rd` files; update roxygen comments
  and run `make rd`.

- Before release-like pushes, run:

  ``` sh
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
