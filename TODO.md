# Rducks TODO

This file is development-facing. Keep user-facing changes in `NEWS.md`
and README/docs. Do not use this file as a historical changelog; it
should describe what still needs doing.

## Current facts

- Current working tree was audited from base commit `8ca0890`.
- Local validation after this audit:
  - `make check` OK
  - `make test` OK: 762 tinytest results
  - `Rscript tools/run_generated_marshalling_matrix.R` OK: 949 generated
    cases
  - `covr::package_coverage(type = "tests")` OK: 85.35% overall coverage
- Recent architecture-audit fixes include database-runtime-scoped R
  metadata, opaque evaluator handles, non-destructive
  [`rducks_release()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_release.md),
  main-thread release queues, direct-only scalar/vectorized `arrow_c`,
  native Arrow IPC encoding without rawConnection fallback, structural
  Arrow IPC type validation, copied Arrow result import, callback error
  fences, dev-only diagnostic SQL probes, capability-guarded backend
  setting, richer queue/runtime diagnostics, concrete execution
  `engine_id`s, and a split R-side Arrow/IPC/provider helper layout.
- Open unchecked TODO items below are expected to be genuinely open,
  blocked by missing upstream lifecycle/removal hooks, or intentionally
  future architecture; they should not describe already-finished work.
- GitHub Actions/R-universe status was not rechecked while refreshing
  this file; use the workflow badges and R-universe package page for
  current hosted status.

## Expert-review checklist status

Database/runtime identity: use Rducks-owned database runtime tokens for
shared registration metadata; connection tokens are only
attachment/default plan bookkeeping.

Registration safety: no raw `SEXP` pointer-through-SQL evaluator
handles; native registration validates opaque evaluator id/token pairs.

Main-thread queue simplification: removed the synthetic worker
self-shim; main-thread callbacks execute inline and drain queued work
cooperatively.

Preserved R object lifetime: off-main native metadata destruction queues
preserved evaluator releases for recorded-main-thread drain points.

Longjmp/error fences: native IPC encoding, direct `arrow_c`, Arrow/R,
and RIPC submit/collect paths use `R_UnwindProtect()`/R error boundaries
where R errors could otherwise cross DuckDB callbacks or skip native
cleanup.

Honest `arrow_c`: scalar and vectorized `arrow_c` are direct-only;
unsupported signatures fail instead of falling back to Arrow/R helpers.

Arrow IPC validation/fallbacks: structural type validation replaces the
fake unsupported-type check, and the primary IPC encoder has no
rawConnection fallback.

Result import lifetime: imported Arrow result chunks are copied into
callback-owned DuckDB output vectors before temporary chunks are
destroyed.

Production SQL surface: dev/test probes are gated by
`RDUCKS_DEV_SURFACES=true`; production backend mutation requires the
recorded main-thread capability.

Diagnostics: runtime accounting, preserved-release stats,
pending/running queue pressure, timeout semantics, and main-thread drain
counters are exposed.

Execution-plan simplification: valid plan pairs expose concrete
`engine_id`s while preserving the readable marshalling/concurrency API.

Persistent worker/provider architecture: generic Future remains the
portable reference provider; `docs/PERSISTENT_PROVIDER.md` specifies the
provider contract/envelopes; `rducks_mirai_provider()` starts/stops
persistent mirai daemons, preloads evaluator/schema state, submits only
task metadata plus Arrow IPC bytes, and returns structured result
envelopes. The experimental public `ipc_mirai_pool` engine is selected
with `ipc_provider = "mirai"`.

No `rducks_unregister()` API: DuckDB reports extension-created functions
as internal catalog entries that cannot be dropped through the ordinary
`DROP FUNCTION` path, and destructive database-scoped removal is not
planned for the current package surface. `docs/UNREGISTER.md` documents
the no-unregister policy and intentional catalog/runtime-lifetime
retention of preserved R closures.

`R/arrow_bridge.R` split: core split done.

- `R/aab_arrow_materialize.R` holds Arrow schema/materialization
  helpers.
- `R/aaa_eval_scalar.R` and `R/aaa_eval_vectorized.R` hold
  scalar/vectorized evaluation helpers and load before
  `R/arrow_bridge.R` top-level aliases.
- `R/ipc_codec.R` holds IPC codec helpers, `R/provider_future.R` holds
  the generic Future provider, and `R/provider_mirai.R` /
  `R/provider_mirai_engine.R` hold the persistent mirai provider and
  UDF-engine wrapper. `R/arrow_bridge.R` stays focused on common
  engine/wrapper construction.

## Non-negotiable constraints

- Use DuckDB C API / C extension API only; no DuckDB C++ API in the
  extension.
- Do not mutate duckdb-r internals. Current exception: read-only access
  to the `conn_ref` slot is used as the weakref lifecycle anchor.
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
| `arrow_c + serial` | implemented | implemented | direct native scalar/vectorized evaluators `RC`/`RCV` |
| `arrow_c + inproc_concurrent` | implemented | implemented | queued same-process callbacks with direct `arrow_c` marshalling |
| `arrow_ipc + multiprocess_parallel` | implemented | implemented | Arrow IPC path through `ipc_future_pool` or experimental `ipc_mirai_pool`, evaluator `RIPC` |

Implemented behavior to preserve:

- Every valid `marshalling + concurrency` pair maps to a concrete
  `engine_id`: `arrow_r_serial`, `arrow_r_main_queue`,
  `arrow_c_direct_serial`, `arrow_c_direct_main_queue`,
  `ipc_future_pool`, or `ipc_mirai_pool`. These engine ids are accepted
  as internal shortcuts while the user-facing pair API remains stable.
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
- DuckDB exposes an instance-cache C API: cached opens can return
  distinct `duckdb_database` handles backed by the same underlying
  database instance. DuckDB extension loading also hands C extensions a
  load-state `DatabaseWrapper`. Therefore raw `duckdb_database` wrapper
  pointers are not a durable runtime identity.
- Rducks UDFs are database/catalog-scoped, not only connection-scoped: a
  UDF registered on one connection is callable from another connection
  to the same database. A weakref finalizer for one collected connection
  must therefore not blindly release preserved R functions while another
  live connection can still call catalog entries that point at the same
  native metadata.
- Implemented R-side baseline: `.rducks_state$connection_plans` and
  `.rducks_state$registrations` are keyed by Rducks-generated connection
  tokens, not SEXP addresses. A
  [`reg.finalizer()`](https://rdrr.io/r/base/reg.finalizer.html) weakref
  on duckdb-r’s `conn_ref` removes those token-keyed entries when the
  external pointer is collected.
- Important limitation: if a preserved UDF closure environment itself
  references the DuckDB connection, the connection is still reachable
  and the weakref finalizer correctly cannot run. Explicit release is
  still needed to break that class of cycle.
- A small C probe showed the current R runtime finalizes independently
  unreachable external pointers in reverse registration order, so an
  Rducks guard external pointer registered after duckdb-r’s `conn_ref`
  finalizer can empirically run first. R’s
  [`reg.finalizer()`](https://rdrr.io/r/base/reg.finalizer.html)
  documentation does not promise this ordering, so this must not be the
  primary lifecycle guarantee. Cleanup must be idempotent and must not
  depend on whether duckdb-r’s disconnect finalizer has already run.

## Resolved and still-open design decisions

Resolved decisions:

- **Connection object model:** Rducks keeps plain `duckdb_connection`
  objects, uses read-only access to duckdb-r’s `conn_ref` external
  pointer as the weakref anchor, and documents explicit
  `rducks_release(con)` before `DBI::dbDisconnect(con)` for
  deterministic R-side cleanup. It does not add an S4 subclass only to
  intercept disconnect.
- **Runtime token contents:** native runtime identity is an Rducks-owned
  process-local `(runtime_id, generation)` token, not a raw
  `duckdb_database` pointer, DuckDB connection id, or R object address.
- **Registration-time marshalling:** the execution plan active at
  [`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md)
  freezes the UDF’s evaluator/marshalling metadata. Later plan changes
  affect connection defaults and the native concurrency backend; they do
  not retarget already-registered UDFs.
- **[`rducks_inproc_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_inproc_stats.md)
  scope:** runtime-wide queue pressure counters live in
  [`rducks_inproc_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_inproc_stats.md),
  while per-UDF evaluator/batching counters live in
  [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md).
- **Duplicate same-signature registration:** current behavior replaces
  the callable implementation for the same SQL name/signature in the
  shared DuckDB database catalog. README/roxygen wording and tinytests
  now cover that replacement behavior.

Still-open or blocked decisions:

- **Native runtime reclamation:** DuckDB’s C extension API still does
  not expose a safe database-close hook for deterministic reclamation of
  process-lifetime native runtime entries and successful extension-owned
  connections. Rducks exposes retention/accounting diagnostics and keeps
  R-side release non-destructive.
- **No unregister API:** ordinary `DROP FUNCTION` cannot drop
  extension-created internal catalog entries, and destructive
  database-scoped removal is not part of the supported package surface.
  Catalog-owned R closures may be retained for the database/runtime
  lifetime rather than being released from connection cleanup.

## P0: connection identity and lifecycle

Replace SEXP-address keying for R-side connection state.

- Current implementation: Rducks-generated connection attachment tokens
  are assigned per duckdb-r `conn_ref` external pointer and used for
  `.rducks_state$connection_plans` only.
- Current lifecycle anchor: `reg.finalizer(conn_ref, ...)` removes the
  connection-local plan store when the DuckDB connection external
  pointer is collected.
- Covered by `inst/tinytest/test_duckdb_runtime_lifecycle.R`.

Make R-side registration metadata database-runtime scoped.

- The native extension exposes an Rducks-owned process-local runtime
  token via `rducks_runtime_token()`; it is based on an internal runtime
  id/generation, not a raw `duckdb_database` pointer, DuckDB connection
  id, or R object address.
- `.rducks_state$registrations` is keyed by that database runtime token,
  so sibling DBI connections to the same DuckDB catalog share the same
  Rducks UDF registry view.
- R-side runtime anchors keep database-scoped registration metadata
  while at least one Rducks-enabled connection attachment is live; when
  the last attachment external pointer is collected, the R-side registry
  cache is removed without dropping DuckDB catalog functions or
  releasing native-owned closures.

Remove raw SEXP pointer-through-SQL evaluator registration.

- [`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md)
  now stores the evaluator in a temporary R-side registry and passes an
  opaque evaluator id/token to the DuckDB extension.
- Manual SQL calls with invalid handles fail with a normal Rducks/DuckDB
  error instead of letting native code cast arbitrary integers to
  `SEXP`.

Expose native runtime retention/accounting diagnostics.

- [`rducks_runtime_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_runtime_stats.md)
  reports native runtime registry entries, active/stale entry counts,
  opened/closed/failure counters, and R-side derived fields for current
  retained extension-owned connections and
  `native_release_supported = FALSE`.
- The runtime token and R-side anchors exist, but native runtime entries
  and successful extension-owned connections are still retained for the
  process lifetime because the DuckDB C extension API does not provide a
  suitable database-close callback.

Implement native runtime reclamation if DuckDB exposes a safe
database-close callback or removable extension-owned connection
lifecycle hook.

- Acceptance: repeated connect/register/disconnect/reconnect loops
  cannot leak unbounded native runtime entries or retain stale native
  backend state.

Implement non-destructive R-side connection release/detach.

- `rducks_release(con)` / `rducks_detach(con)` now remove this
  connection’s R-side attachment token, current/default plan, and
  runtime anchor.
- Release is idempotent and non-destructive: it does not
  `DROP FUNCTION`, does not unregister database-catalog UDFs, and does
  not release native-owned R closures referenced by DuckDB catalog
  metadata.
- If sibling DBI connections are still attached to the same database
  runtime, the shared database-scoped registration cache remains
  visible. When the last R-side anchor is released or finalized, only
  the R registration cache is removed.
- Native runtime entries and extension-owned connections still need
  separate release accounting; see the native runtime release item
  above.
- Must not call DBI/SQL from finalizers.
- Must not call R API from off-main native destructors.

Integrate release with `dbDisconnect()` if the connection object model
permits it.

- Rducks retains the plain `duckdb_connection` object and therefore does
  not override DBI’s `dbDisconnect()` method.
- [`rducks_release()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_release.md)
  documentation now explicitly recommends calling `rducks_release(con)`
  before `DBI::dbDisconnect(con)` for deterministic connection-local
  cleanup; weak-reference finalizers remain best-effort.
- Basic idempotent/non-destructive release behavior is covered in
  `inst/tinytest/test_duckdb_runtime_lifecycle.R`.

Add repeated lifecycle tests.

- Repeated `:memory:` connections now enable Rducks, register UDFs,
  query, explicitly release, disconnect, force GC, and assert R-side
  plan/runtime and registration stores do not expose stale entries.
- Native runtime entries and extension-owned connections still need
  separate release accounting; see the native runtime release item
  above.

## P1: correctness hardening

Remove the main-thread self-shim and its unbounded join.

- Main-thread in-process callbacks now drain queued worker requests
  before and after inline execution instead of spawning a synthetic
  worker thread.

Fix or document queued request waits once a request is `RUNNING`.

- [`rducks_inproc_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_inproc_stats.md)
  exposes `running_timeout_supported = FALSE` and
  `docs/SUPPORT_MATRIX.md` explains that once a queued request is
  running, borrowed DuckDB callback-frame input/output storage prevents
  safe cancellation; only pending timeout is supported.

Add stress tests for no-deadlock behavior.

- Default tinytests cover queued scalar/vectorized `arrow_r` and direct
  `arrow_c` execution through `rducks_parallel_range()` and assert
  submitted requests complete without timeouts.
- `RDUCKS_STRESS_CONCURRENCY=true` enables a larger multi-threaded
  queued UDF stress case.

Add a main-thread release queue for preserved R objects, or explicitly
document the leak-until-session-end policy.

- Native UDF metadata destructors now release preserved evaluator
  objects immediately only on the recorded main R thread; off-main
  destructors enqueue them for later safe release.
- Safe drain points include
  [`rducks_enable()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable.md),
  [`rducks_release()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_release.md),
  [`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md),
  UDF execution, and metadata/stat queries.
- [`rducks_release_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_release_stats.md)
  exposes queued/released/failed/pending counters.

Extend no-fallback assertions for `arrow_c` direct registration.

- `arrow_c` registration now fails for signatures that cannot yet use
  the native direct DuckDB-vector path instead of falling through to the
  R/Arrow bridge.
- Supported direct cases include scalar, DECIMAL, ENUM, STRUCT, UNION,
  and LIST/ARRAY/MAP descriptors whose element/key/value types are
  accepted by the stricter sequence-child support predicate. For
  example, top-level `BIGINT` is direct-supported but `BIGINT[]` is
  deliberately rejected until exact integer vector storage is
  implemented for homogeneous sequences.

Add generated matrix no-fallback coverage for every supported scalar,
DECIMAL, ENUM, LIST, ARRAY, STRUCT, MAP, and UNION direct type.

- Acceptance:
  [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)
  shows `arrow_c_chunks > 0` and `arrow_r_chunks == 0` for supported
  scalar and vectorized `arrow_c` cases. Vectorized `arrow_c` uses `RCV`
  direct native materialization rather than the old Arrow/R helper
  bridge.
- The generated matrix now asserts the expected direct-support allowlist
  and runs scalar/vectorized no-fallback counter checks for descriptors
  that the direct-support predicates accept, including default/special
  NULL handling and `exception_handling = "return_null"` smoke cases.
  Latest run: 1213 cases.

Implement native direct `arrow_c` composite/union marshalling.

- Done: recursive DuckDB-vector readers/writers for LIST, ARRAY, STRUCT,
  MAP, and UNION.
- Acceptance: those scalar signatures register under `arrow_c`, execute
  through `arrow_c_chunks`, and keep `arrow_r_chunks == 0`.

Handle partial failures in
[`rducks_set_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_set_execution_plan.md).

- Thread settings are restored when thread/backend setup fails before
  the R-side plan cache is updated.
- Backend mutation is now performed while Rducks briefly forces
  single-thread SQL execution, so the capability-guarded backend setter
  runs on the recorded main R thread before requested parallel DuckDB
  settings are restored.

Defensively clear Arrow C Data release callbacks on conversion failure.

- DuckDB Arrow schema/export conversion errors now immediately release
  and null any partially-populated `ArrowSchema`/`ArrowArray` callbacks
  before returning through the UDF error path.

Re-audit Arrow validity handling.

- `rducks_arrow_validity()` now explicitly accepts nanoarrow’s logical
  validity buffers and raw bit-packed Arrow validity buffers, honors
  array offsets, rejects short buffers, and has focused tinytest
  coverage.

Audit remaining `Rf_*` longjmp paths.

- IPC native encoding uses `R_UnwindProtect()` around raw-vector
  allocation/copy so Arrow writer, stream, preserved nanoarrow external
  pointers, and native buffers are released if `Rf_allocVector()`
  longjmps.
- Direct `arrow_c`, Arrow/R, and RIPC submit/collect callbacks are
  fenced with `R_tryCatchError()` + `R_UnwindProtect()`; RIPC
  abnormal-unwind cleanup releases preserved Future/schema objects and
  marks in-flight tasks done.
- The remaining direct `arrow_c` conversion helpers called inside DuckDB
  callbacks borrow callback vectors, allocate temporary C buffers with
  `R_alloc()`, or allocate R-managed `SEXP`s under the top-level arrow_c
  error boundary. No remaining callback path holds `malloc`/Arrow/DuckDB
  handles across a raw `Rf_error()` without a cleanup boundary.
- Package `.Call` helper code outside DuckDB callbacks may still use
  ordinary R errors, but those paths do not cross DuckDB callback frames
  or hold native callback-frame resources.

Add GC/lifetime tests.

- Tests drop R registration objects, run
  [`gc()`](https://rdrr.io/r/base/gc.html), then call DuckDB UDFs.
- Lifecycle tests close/release connections after registrations and
  confirm no crashes or stale R-side metadata in
  plan/runtime/registration stores.

## P2: observability and diagnostics

Expand
[`rducks_inproc_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_inproc_stats.md)
beyond submitted/executed/timeouts.

- Runtime-wide pending/running current and max counters are exposed
  alongside submitted, executed, timeouts, configured pending timeout,
  explicit running-timeout support status, main-thread drain attempts,
  non-empty drain batches, and maximum drain batch size.

Gate dev/test SQL probes behind `RDUCKS_DEV_SURFACES=true`.

- `rducks_parallel_range`, `rducks_parallel_thread_probe`,
  `rducks_queue_self_test`, and `rducks_thread_is_main` no longer
  register as production SQL functions by default.
- The production backend setter remains for R-side plan control but now
  requires the recorded main-thread capability payload; bare manual SQL
  calls cannot mutate runtime backend state.

Add counter reset support.

- `rducks_reset_udf_counters(con, name)` resets one UDF; `name = NULL`
  resets all native UDF counters in the database runtime without
  unregistering catalog functions.

Expose native current-backend diagnostics.

- [`rducks_native_execution_backend()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_native_execution_backend.md)
  returns the database-scoped native backend so
  [`rducks_current_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_current_execution_plan.md)
  can be cross-checked against native backend state.

Mark or skip missing R-side registration records.

- [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)/[`rducks_list_udfs()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_list_udfs.md)
  include `r_side_record` so rows whose native catalog metadata outlives
  the detached R-side registry are explicit instead of silently
  appearing as ordinary managed records.

Discover native UDF stat fields instead of querying a hand-mirrored R
vector.

- Native `rducks_udf_stat_fields()` exposes the C stat field list and
  `rducks_native_udf_stats()` uses it after validating it against the
  known fallback list, with the old R vector retained for
  compatibility/name collision fallback.

## P2/P3: Arrow IPC and worker execution

Fix cooperative RIPC counter under-reporting.

- Main-thread cooperative RIPC local requests now increment runtime-wide
  submitted/executed/running queue counters, so runtime queue stats are
  no longer lower than per-UDF queued chunk counts on the cooperative
  path.

Remove the hidden slow R encoder fallback from the primary Arrow IPC
encoder.

- `rducks_arrow_ipc_encode()` now requires a `nanoarrow_array` and uses
  the native encoder only.
- The former
  [`nanoarrow::write_nanoarrow()`](https://arrow.apache.org/nanoarrow/latest/r/reference/read_nanoarrow.html)
  / [`rawConnection()`](https://rdrr.io/r/base/rawConnection.html)
  fallback is no longer present in package code.

Replace fake Arrow IPC unsupported-type validation with a structural
type check over scalar, DECIMAL, ENUM, LIST, ARRAY, STRUCT, MAP, and
UNION types.

Reduce Arrow IPC/Future overhead for cheap UDFs without hidden fallback
within the generic Future provider.

- Arrow IPC Future wrappers cache the output schema spec at registration
  wrapper scope after the first chunk, avoiding repeated schema-to-list
  conversion on every submission.
- `future_globals` now defaults to `"auto"`, so generic Future UDF
  globals are discovered once at wrapper creation and chunk submissions
  send explicit worker state instead of running automatic global
  discovery every time. Users can still opt into per-task discovery with
  `TRUE`, required-state only with `FALSE`, or explicit
  character/named-list globals.
- The experimental `ipc_mirai_pool` engine preloads evaluator state and
  schema once and submits only task id/UDF id/row count/IPC bytes per
  chunk.
- `tools/benchmark_ipc_providers.R` compares
  [`future::multisession`](https://future.futureverse.org/reference/multisession.html),
  [`future.mirai::mirai_multisession`](https://future.mirai.futureverse.org/reference/mirai_multisession.html),
  and direct `ipc_mirai_pool` paths using the same provider-level Arrow
  IPC payload.

Improve batching beyond small waves for typical DuckDB physical scans.

- `ipc_mirai_pool` now has provider-level backpressure via
  `ipc_max_pending`, so persistent workers cannot accumulate unbounded
  accepted-but-uncollected tasks.
- The mirai provider now exposes tested `collect_any()` behavior so
  ready tasks can be collected without waiting for an earlier slow task;
  native callback writeback still waits for grouped collect results, so
  larger collect-any scheduling remains open.

Specify a persistent worker/request envelope if generic `future` is not
enough.

- `docs/PERSISTENT_PROVIDER.md` defines provider operations,
  registration/task/result envelopes,
  collect-any/backpressure/cancellation expectations, and keeps the hot
  data path as Arrow IPC bytes with no R
  [`serialize()`](https://rdrr.io/r/base/serialize.html) /
  [`unserialize()`](https://rdrr.io/r/base/serialize.html) fallback for
  chunk payloads.

Decide worker transport beyond generic `future` if needed.

- `docs/PERSISTENT_PROVIDER.md` keeps generic Future as the correctness
  adapter, selects mirai as the first persistent-worker target, and
  defers nanonext to a later lower-level transport if public APIs are
  needed.
- Do not link against uninstalled `nanonext.so` internals.

Prototype persistent worker startup/shutdown, cancellation, and error
propagation.

- Internal `rducks_mirai_provider()` implements start/stop,
  register_udf, submit, collect_any, collect_many, cancel, and stats
  using persistent mirai daemons and preloaded UDF records.
- Focused tinytests cover successful Arrow IPC task execution,
  structured worker errors, and provider counters.

Wire a persistent worker provider into a public UDF engine with no
hidden fallback.

- `rducks_execution_plan("arrow_ipc", "multiprocess_parallel", ipc_provider = "mirai")`
  selects `ipc_mirai_pool`.
- The first implementation uses the existing RIPC callback/writeback
  path and mirai task envelopes. Bounded backpressure remains part of
  the batching item above rather than a hidden fallback.

## P3: owned same-process chunk boundaries

The current in-process queue is synchronous and borrows DuckDB
input/output pointers only for the duration of a scalar UDF callback.
That is acceptable for current callbacks, but not for an asynchronous
same-process design.

Implement owned input snapshots for worker-originating chunk requests.

Implement owned result payloads plus safe writeback.

Split current `arrow_c` code into explicit worker-safe/native and
recorded-main-R-thread phases.

- Scalar `arrow_c` now snapshots borrowed DuckDB vector views in a
  no-R-API phase, then runs R argument materialization/evaluation/SEXP
  writeback in a named main-thread phase while the callback remains
  blocked.
- Vectorized `arrow_c` now has named main-thread
  prepare/evaluate/writeback phases. Fully worker-safe vectorized
  snapshots still depend on the owned input/result payload items above.

## Wasm / webR

wasm builds on R-universe for the current baseline.

Add a webR runtime smoke test harness, not just a build test.

- `scripts/start_webr_local_test.sh` builds the `.tgz`, creates a local
  webR repository, and serves `scripts/webr-local-test.html`.
- The browser smoke installs the built `.tgz` in webR, loads Rducks,
  runs public native/type helpers, and attempts minimal DuckDB extension
  load/register/query when the webR DuckDB runtime supports it.
- `.github/workflows/webr-smoke.yaml` runs the browser smoke through
  Chromium/Playwright on push, pull request, and manual dispatch.
  Package docs still avoid claiming webR runtime support unless that
  workflow is green for the target runtime and proves extension
  load/register/query behavior.

Document wasm support level.

- `docs/WASM.md` clarifies that wasm/webR support remains experimental
  and must not be claimed as runtime-supported until the local browser
  smoke is run in CI and proves extension-load/register/query behavior.

## Documentation backlog

README documents `arrow_lossless_conversion=true`.

README quick start shows a zero-argument scalar UDF with `args = NULL`.

README in-process queue example uses a DuckDB table scan with
`threads = 4, external_threads = 1`, reports main-thread vs
worker-thread probe rows, and states that speedup should not be
inferred.

README uses explicit main-thread / worker-thread wording.

Update `docs/EXECUTION_PLANS.md`.

- Includes the concrete implemented engine matrix, no-fallback
  principle, registration-time/frozen engine behavior, direct-only
  `arrow_c`, database-catalog versus connection-detach scope, and
  current diagnostic hooks including
  [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)/[`rducks_native_execution_backend()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_native_execution_backend.md).

Keep roxygen/Rd wording aligned with README.

- Current audit refreshed the execution-plan and registration roxygen
  blocks, regenerated Rd with `make rd`, and removed stale
  connection/session wording.

Publish an explicit type/mode/plan support table.

- `docs/SUPPORT_MATRIX.md` covers scalar/vectorized engine support,
  `arrow_r`/direct `arrow_c`/experimental `arrow_ipc`, type-family
  coverage, NULL/error policy, and copy/borrow expectations.

Clarify ownership/lifetime semantics.

- `docs/SUPPORT_MATRIX.md` documents process, database/catalog runtime,
  and DBI connection attachment scope, preserved R closures, main-thread
  release queue behavior, and why running queued cancellation is
  unsupported.

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
