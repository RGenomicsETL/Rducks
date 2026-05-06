# Rducks TODO

This file is development-facing. Keep user-facing changes in `NEWS.md` and
README/docs. Do not use this file as a historical changelog; it should describe
what still needs doing.

## Current facts

- Current development baseline when this file was refreshed: `cf4b007`.
- Local validation at that baseline:
  - `R CMD INSTALL .` OK
  - `make test` OK: 652 tinytest results
  - `Rscript tools/run_generated_marshalling_matrix.R` OK: 945 generated cases
- Recent architecture-audit fixes include database-runtime-scoped R metadata,
  opaque evaluator handles, non-destructive `rducks_release()`, main-thread
  release queues, direct-only scalar/vectorized `arrow_c`, native Arrow IPC
  encoding without rawConnection fallback, structural Arrow IPC type validation,
  copied Arrow result import, callback error fences, dev-only diagnostic SQL
  probes, capability-guarded backend setting, richer queue/runtime diagnostics,
  and concrete execution `engine_id`s.
- GitHub Actions/R-universe status was not rechecked while refreshing this file;
  use the workflow badges and R-universe package page for current hosted status.

## Expert-review checklist status

- [x] Database/runtime identity: use Rducks-owned database runtime tokens for
  shared registration metadata; connection tokens are only attachment/default
  plan bookkeeping.
- [x] Registration safety: no raw `SEXP` pointer-through-SQL evaluator handles;
  native registration validates opaque evaluator id/token pairs.
- [x] Main-thread queue simplification: removed the synthetic worker self-shim;
  main-thread callbacks execute inline and drain queued work cooperatively.
- [x] Preserved R object lifetime: off-main native metadata destruction queues
  preserved evaluator releases for recorded-main-thread drain points.
- [x] Longjmp/error fences: native IPC encoding, direct `arrow_c`, Arrow/R, and
  RIPC submit/collect paths use `R_UnwindProtect()`/R error boundaries where R
  errors could otherwise cross DuckDB callbacks or skip native cleanup.
- [x] Honest `arrow_c`: scalar and vectorized `arrow_c` are direct-only; unsupported
  signatures fail instead of falling back to Arrow/R helpers.
- [x] Arrow IPC validation/fallbacks: structural type validation replaces the
  fake unsupported-type check, and the primary IPC encoder has no rawConnection
  fallback.
- [x] Result import lifetime: imported Arrow result chunks are copied into
  callback-owned DuckDB output vectors before temporary chunks are destroyed.
- [x] Production SQL surface: dev/test probes are gated by
  `RDUCKS_DEV_SURFACES=true`; production backend mutation requires the recorded
  main-thread capability.
- [x] Diagnostics: runtime accounting, preserved-release stats, pending/running
  queue pressure, timeout semantics, and main-thread drain counters are exposed.
- [x] Execution-plan simplification: valid plan pairs expose concrete
  `engine_id`s while preserving the readable marshalling/concurrency API.
- [ ] Persistent worker/provider architecture: generic Future remains the
  portable reference provider; persistent mirai/nanonext-style workers with
  preloaded evaluator/schema state are still future work.
- [ ] `rducks_unregister()`: not implemented; DuckDB reports extension-created
  functions as internal catalog entries that cannot be dropped through the
  ordinary `DROP FUNCTION` path, so destructive database-scoped unregistering
  needs a separate design.
- [ ] `R/arrow_bridge.R` split: partially done. IPC codec helpers live in
  `R/ipc_codec.R` and the generic Future provider lives in
  `R/provider_future.R`; schema/materialization/eval helpers still need a later
  split when the provider abstraction is reworked.

## Non-negotiable constraints

- Use DuckDB C API / C extension API only; no DuckDB C++ API in the extension.
- Do not mutate duckdb-r internals. Current exception: read-only access to the
  `conn_ref` slot is used as the weakref lifecycle anchor.
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
| `arrow_c + serial` | implemented | implemented | direct native scalar/vectorized evaluators `RC`/`RCV` |
| `arrow_c + inproc_concurrent` | implemented | implemented | queued same-process callbacks with direct `arrow_c` marshalling |
| `arrow_ipc + multiprocess_parallel` | implemented | implemented | Future-backed Arrow IPC path, evaluator `RIPC` |

Implemented behavior to preserve:

- Every valid `marshalling + concurrency` pair maps to a concrete `engine_id`:
  `arrow_r_serial`, `arrow_r_main_queue`, `arrow_c_direct_serial`,
  `arrow_c_direct_main_queue`, or `ipc_future_pool`. These engine ids are
  accepted as internal shortcuts while the user-facing pair API remains stable.
- The active plan at `rducks_register()` chooses the native evaluator stored in
  DuckDB UDF metadata (`R`, `RC`, `RCV`, or `RIPC`). Later plan changes alter the
  runtime concurrency backend, but do not retarget already-registered UDF
  marshalling.
- Zero-argument scalar UDFs use `args = NULL`.
- Zero-argument vectorized UDFs are not exposed.
- `side_effects = TRUE` marks the DuckDB scalar function volatile; it does not
  alter R-thread or queue semantics.

## Empirical notes from connection-object checks

Run with `lobstr` in this session:

- `duckdb_connection` is an S4 object (`typeof(con) == "S4"`), not an
  environment (`is.environment(con) == FALSE`). It contains slots including
  `conn_ref`, but the R wrapper itself follows ordinary copy-on-modify behavior.
- Setting an attribute on `con` inside a helper function changed the helper's
  local copy, not the caller's object. Therefore a hidden attribute/guard or S4
  subclass only works if the user keeps the returned object, e.g.
  `con <- rducks_enable(con)`.
- Calling `rducks_enable(con)` without assignment did not change the R wrapper
  address or attributes; it only changed DuckDB/Rducks state reachable through
  the external pointer and package stores.
- Opening several independent `:memory:` databases in one R session produced
  distinct live SEXP keys, but DuckDB `current_connection_id()` was the same for
  each independent database instance. Two connections from the same duckdb
  driver/database produced different `current_connection_id()` values. So a
  DuckDB connection id is useful within a database instance but is not a global
  R-side connection key by itself.
- duckdb-r registers `reg.finalizer(conn@conn_ref, onexit = TRUE,
  rapi_disconnect)` when connecting. Therefore the DuckDB connection is
  disconnected by GC/session-exit finalization when `conn@conn_ref` becomes
  unreachable, even if users never call `DBI::dbDisconnect()`.
- S4 class extension does not itself create a finalizer. R finalizers are only
  for environments and external pointers.
- Current R weak references can only use reference objects as keys
  (`NILSXP`, `ENVSXP`, `EXTPTRSXP`, or byte-code objects), not the S4
  `duckdb_connection` wrapper itself. A no-subclass GC cleanup path therefore
  needs either a weak reference/finalizer keyed by duckdb-r's `conn_ref`
  external pointer, or an assigned Rducks-owned guard environment/externalptr.
- DuckDB exposes an instance-cache C API: cached opens can return distinct
  `duckdb_database` handles backed by the same underlying database instance.
  DuckDB extension loading also hands C extensions a load-state
  `DatabaseWrapper`. Therefore raw `duckdb_database` wrapper pointers are not a
  durable runtime identity.
- Rducks UDFs are database/catalog-scoped, not only connection-scoped: a UDF
  registered on one connection is callable from another connection to the same
  database. A weakref finalizer for one collected connection must therefore not
  blindly release preserved R functions while another live connection can still
  call catalog entries that point at the same native metadata.
- Implemented R-side baseline: `.rducks_state$connection_plans` and
  `.rducks_state$registrations` are keyed by Rducks-generated connection tokens,
  not SEXP addresses. A `reg.finalizer()` weakref on duckdb-r's `conn_ref`
  removes those token-keyed entries when the external pointer is collected.
- Important limitation: if a preserved UDF closure environment itself references
  the DuckDB connection, the connection is still reachable and the weakref
  finalizer correctly cannot run. Explicit release is still needed to break that
  class of cycle.
- A small C probe showed the current R runtime finalizes independently
  unreachable external pointers in reverse registration order, so an Rducks
  guard external pointer registered after duckdb-r's `conn_ref` finalizer can
  empirically run first. R's `reg.finalizer()` documentation does not promise
  this ordering, so this must not be the primary lifecycle guarantee. Cleanup
  must be idempotent and must not depend on whether duckdb-r's disconnect
  finalizer has already run.

## Decisions needed

1. **Connection object model for R-side state.**
   - R-side SEXP-address keying has been replaced for plan/registration stores.
   - Empirical result: S4 `duckdb_connection` wrappers are not environments and
     are not mutated in the caller by assigning attributes inside
     `rducks_enable()` unless the modified object is returned and assigned.
   - Chosen baseline: no S4 subclass is needed merely to clear Rducks R-side
     state when the DuckDB connection external pointer is collected. Rducks now
     uses read-only access to duckdb-r's `conn_ref` slot as the weakref anchor.
   - Remaining decision: whether to add a subclass/wrapper only to intercept
     explicit `DBI::dbDisconnect(con)` and run Rducks cleanup immediately before
     delegating to duckdb-r.

2. **Runtime token contents.**
   - Problem: DuckDB `current_connection_id()` is not globally unique across
     independent database instances; raw wrapper addresses can be reused.
   - Additional problem: DuckDB's C instance-cache API can create multiple
     `duckdb_database` wrapper handles for the same underlying database
     instance, and extension loading creates a load-state wrapper. Do not use
     raw `duckdb_database` pointers as stable runtime ids.
   - Decision: define a native Rducks token such as `(runtime_id, generation)`.
     It may include DuckDB database/connection details for diagnostics, but the
     unique part should be Rducks-owned and monotonic within the process.

3. **Runtime release API shape and finalizer ordering.**
   - Problem: DuckDB has no database/connection close hook in the C extension
     API. The extension-owned connection can pin the runtime.
   - GC path: key Rducks cleanup to collection of the DuckDB connection external
     pointer, clear token-keyed R stores, and call a native idempotent release
     path that does not require a live DuckDB connection.
   - Do not equate one connection's collection with database-runtime death.
     Track Rducks-enabled connection anchors per runtime. Only runtime-wide
     release should consider dropping/releasing UDF state.
   - If releasing preserved R functions from the weakref finalizer, first make
     native UDF metadata inert under lock: future calls must error cleanly rather
     than calling a released `SEXP`, and later DuckDB metadata destructors must
     not double-release. Releasing is only safe when no in-flight callbacks use
     the metadata.
   - Explicit disconnect caveat: if users call `DBI::dbDisconnect(con)` but keep
     `con` referenced, a weakref/finalizer will not run until `con@conn_ref`
     becomes unreachable. A subclass/wrapper or explicit `rducks_release(con)` is
     still needed for deterministic cleanup at disconnect time.
   - Cleanup must not rely on finalizer ordering relative to duckdb-r's own
     `conn_ref` finalizer.
   - Non-decision already made for now: native cleanup may leak preserved R
     closures rather than calling R API off the main R thread.

4. **Duplicate registration semantics.**
   - Decide whether duplicate `name`/signature registration errors, overwrites,
     or creates overloads.
   - This blocks clear `rducks_unregister()` semantics.

5. **Registration-time vs query-time marshalling contract.**
   - Current implementation is registration-time marshalling.
   - Decision: document this as public semantics now, or redesign for query-time
     marshalling dispatch.
   - My recommendation: document registration-time marshalling for now.

6. **`rducks_inproc_stats()` scope.**
   - Current function exposes runtime-wide `submitted`, `executed`, `timeouts`.
   - Per-UDF pressure/batching counters are available through
     `rducks_explain_udf()`.
   - Decide whether to keep `rducks_inproc_stats()` intentionally minimal or add
     runtime-wide pending/max counters.

## P0: connection identity and lifecycle

- [x] Replace SEXP-address keying for R-side connection state.
  - Current implementation: Rducks-generated connection attachment tokens are
    assigned per duckdb-r `conn_ref` external pointer and used for
    `.rducks_state$connection_plans` only.
  - Current lifecycle anchor: `reg.finalizer(conn_ref, ...)` removes the
    connection-local plan store when the DuckDB connection external pointer is
    collected.
  - Covered by `inst/tinytest/test_duckdb_runtime_lifecycle.R`.

- [x] Make R-side registration metadata database-runtime scoped.
  - The native extension exposes an Rducks-owned process-local runtime token via
    `rducks_runtime_token()`; it is based on an internal runtime id/generation,
    not a raw `duckdb_database` pointer, DuckDB connection id, or R object
    address.
  - `.rducks_state$registrations` is keyed by that database runtime token, so
    sibling DBI connections to the same DuckDB catalog share the same Rducks UDF
    registry view.
  - R-side runtime anchors keep database-scoped registration metadata while at
    least one Rducks-enabled connection attachment is live; when the last
    attachment external pointer is collected, the R-side registry cache is
    removed without dropping DuckDB catalog functions or releasing native-owned
    closures.

- [x] Remove raw SEXP pointer-through-SQL evaluator registration.
  - `rducks_register()` now stores the evaluator in a temporary R-side registry
    and passes an opaque evaluator id/token to the DuckDB extension.
  - Manual SQL calls with invalid handles fail with a normal Rducks/DuckDB
    error instead of letting native code cast arbitrary integers to `SEXP`.

- [ ] Add native runtime release accounting.
  - The runtime token and R-side anchors exist, but native runtime entries and
    extension-owned connections are still retained for the process lifetime.
  - Add native release accounting separately from the R-side cleanup now in
    place.
  - Acceptance: repeated connect/register/disconnect/reconnect loops cannot leak
    unbounded native runtime entries or retain stale native backend state.

- [x] Implement non-destructive R-side connection release/detach.
  - `rducks_release(con)` / `rducks_detach(con)` now remove this connection's
    R-side attachment token, current/default plan, and runtime anchor.
  - Release is idempotent and non-destructive: it does not `DROP FUNCTION`, does
    not unregister database-catalog UDFs, and does not release native-owned R
    closures referenced by DuckDB catalog metadata.
  - If sibling DBI connections are still attached to the same database runtime,
    the shared database-scoped registration cache remains visible. When the last
    R-side anchor is released or finalized, only the R registration cache is
    removed.
  - Native runtime entries and extension-owned connections still need separate
    release accounting; see the native runtime release item above.
  - Must not call DBI/SQL from finalizers.
  - Must not call R API from off-main native destructors.

- [ ] Integrate release with `dbDisconnect()` if the connection object model
  permits it.
  - If subclass/wrapper is chosen, implement a `dbDisconnect()` method that calls
    `rducks_release()` before delegating to duckdb-r.
  - If plain `duckdb_connection` is retained, document explicit release. Basic
    idempotent/non-destructive release behavior is covered in
    `inst/tinytest/test_duckdb_runtime_lifecycle.R`.

- [x] Add repeated lifecycle tests.
  - Repeated `:memory:` connections now enable Rducks, register UDFs, query,
    explicitly release, disconnect, force GC, and assert R-side plan/runtime and
    registration stores do not expose stale entries.
  - Native runtime entries and extension-owned connections still need separate
    release accounting; see the native runtime release item above.

## P1: correctness hardening

- [x] Remove the main-thread self-shim and its unbounded join.
  - Main-thread in-process callbacks now drain queued worker requests before and
    after inline execution instead of spawning a synthetic worker thread.

- [ ] Fix or document queued request waits once a request is `RUNNING`.
  - Current timeout only applies while a request is `PENDING` because queued
    scalar UDF requests borrow DuckDB callback-frame input/output storage.

- [ ] Add stress tests for no-deadlock behavior.
  - Repeated queued UDF calls with multiple DuckDB threads should complete or
    fail with documented timeout text, never hang.

- [x] Add a main-thread release queue for preserved R objects, or explicitly
  document the leak-until-session-end policy.
  - Native UDF metadata destructors now release preserved evaluator objects
    immediately only on the recorded main R thread; off-main destructors enqueue
    them for later safe release.
  - Safe drain points include `rducks_enable()`, `rducks_release()`,
    `rducks_register()`, UDF execution, and metadata/stat queries.
  - `rducks_release_stats()` exposes queued/released/failed/pending counters.

- [x] Extend no-fallback assertions for `arrow_c` direct registration.
  - `arrow_c` registration now fails for signatures that cannot yet use the
    native direct DuckDB-vector path instead of falling through to the R/Arrow
    bridge.
  - Supported direct cases include scalar, DECIMAL, ENUM, STRUCT, UNION, and
    LIST/ARRAY/MAP descriptors whose element/key/value types are accepted by the
    stricter sequence-child support predicate. For example, top-level `BIGINT`
    is direct-supported but `BIGINT[]` is deliberately rejected until exact
    integer vector storage is implemented for homogeneous sequences.

- [x] Add generated matrix no-fallback coverage for every supported scalar,
  DECIMAL, ENUM, LIST, ARRAY, STRUCT, MAP, and UNION direct type.
  - Acceptance: `rducks_explain_udf()` shows `arrow_c_chunks > 0` and
    `arrow_r_chunks == 0` for supported scalar and vectorized `arrow_c` cases.
    Vectorized `arrow_c` uses `RCV` direct native materialization rather than
    the old Arrow/R helper bridge.
  - The generated matrix now asserts the expected direct-support allowlist and
    runs scalar `arrow_c` no-fallback counter checks for descriptors that the
    direct-support predicate accepts, including default/special NULL handling
    and `exception_handling = "return_null"` smoke cases.

- [x] Implement native direct `arrow_c` composite/union marshalling.
  - Done: recursive DuckDB-vector readers/writers for LIST, ARRAY, STRUCT, MAP,
    and UNION.
  - Acceptance: those scalar signatures register under `arrow_c`, execute
    through `arrow_c_chunks`, and keep `arrow_r_chunks == 0`.

- [x] Handle partial failures in `rducks_set_execution_plan()`.
  - Thread settings are restored when thread/backend setup fails before the
    R-side plan cache is updated.

- [ ] Defensively clear Arrow C Data release callbacks on conversion failure.

- [ ] Re-audit Arrow validity handling.
  - Current concern: `rducks_arrow_validity()` relies on nanoarrow/DuckDB
    validity-buffer behavior that should be made explicit or guarded.

- [ ] Audit remaining `Rf_*` longjmp paths.
  - Use `R_alloc()` or `R_UnwindProtect()` where heap state would otherwise leak
    across `Rf_error()`.
  - IPC native encoding now uses `R_UnwindProtect()` around raw-vector
    allocation/copy so Arrow writer, stream, preserved nanoarrow external
    pointers, and native buffers are released if `Rf_allocVector()` longjmps.
  - Direct `arrow_c`, Arrow/R, and RIPC submit/collect callbacks are fenced with
    `R_tryCatchError()` + `R_UnwindProtect()`; RIPC abnormal-unwind cleanup
    releases preserved Future/schema objects and marks in-flight tasks done.

- [x] Add GC/lifetime tests.
  - Tests drop R registration objects, run `gc()`, then call DuckDB UDFs.
  - Lifecycle tests close/release connections after registrations and confirm no
    crashes or stale R-side metadata in plan/runtime/registration stores.

## P2: observability and diagnostics

- [x] Expand `rducks_inproc_stats()` beyond submitted/executed/timeouts.
  - Runtime-wide pending/running current and max counters are exposed alongside
    submitted, executed, timeouts, configured pending timeout, explicit
    running-timeout support status, main-thread drain attempts, non-empty drain
    batches, and maximum drain batch size.

- [x] Gate dev/test SQL probes behind `RDUCKS_DEV_SURFACES=true`.
  - `rducks_parallel_range`, `rducks_parallel_thread_probe`,
    `rducks_queue_self_test`, and `rducks_thread_is_main` no longer register as
    production SQL functions by default.
  - The production backend setter remains for R-side plan control but now
    requires the recorded main-thread capability payload; bare manual SQL calls
    cannot mutate runtime backend state.

- [ ] Add counter reset support.
  - Reset one UDF or all UDF counters without unregistering the UDF.

- [x] Expose native current-backend diagnostics.
  - `rducks_native_execution_backend()` returns the database-scoped native
    backend so `rducks_current_execution_plan()` can be cross-checked against
    native backend state.

- [x] Mark or skip missing R-side registration records.
  - `rducks_explain_udf()`/`rducks_list_udfs()` include `r_side_record` so rows
    whose native catalog metadata outlives the detached R-side registry are
    explicit instead of silently appearing as ordinary managed records.

- [x] Discover native UDF stat fields instead of querying a hand-mirrored R
  vector.
  - Native `rducks_udf_stat_fields()` exposes the C stat field list and
    `rducks_native_udf_stats()` uses it after validating it against the known
    fallback list, with the old R vector retained for compatibility/name
    collision fallback.

## P2/P3: Arrow IPC and worker execution

- [ ] Fix cooperative RIPC counter under-reporting.
  - Runtime-wide `submitted/executed` can be lower than per-UDF queued chunk
    counts on cooperative paths.

- [x] Remove the hidden slow R encoder fallback from the primary Arrow IPC
  encoder.
  - `rducks_arrow_ipc_encode()` now requires a `nanoarrow_array` and uses the
    native encoder only.
  - The former `nanoarrow::write_nanoarrow()` / `rawConnection()` fallback is no
    longer present in package code.

- [x] Replace fake Arrow IPC unsupported-type validation with a structural type
  check over scalar, DECIMAL, ENUM, LIST, ARRAY, STRUCT, MAP, and UNION types.

- [ ] Reduce Arrow IPC/Future overhead for cheap UDFs without hidden fallback.
  - Done: Arrow IPC Future wrappers cache the output schema spec at registration
    wrapper scope after the first chunk, avoiding repeated schema-to-list
    conversion on every submission.
  - Done: `future_globals` now defaults to `"auto"`, so generic Future UDF
    globals are discovered once at wrapper creation and chunk submissions send
    explicit worker state instead of running automatic global discovery every
    time. Users can still opt into per-task discovery with `TRUE`, required-state
    only with `FALSE`, or explicit character/named-list globals.
  - Remaining: persistent workers should preload evaluator state and schemas once
    and submit only task id/UDF id/row count/IPC bytes per chunk.

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

- [x] Update `docs/EXECUTION_PLANS.md`.
  - Includes the concrete implemented engine matrix, no-fallback principle,
    registration-time/frozen engine behavior, direct-only `arrow_c`,
    database-catalog versus connection-detach scope, and current diagnostic
    hooks including `rducks_explain_udf()`/`rducks_native_execution_backend()`.
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
