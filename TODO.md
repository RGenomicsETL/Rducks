# Rducks TODO

This file tracks implementation work, tests, and semantic clarifications
that are not yet complete. It is development-facing; user-facing release
notes stay in `NEWS.md`.

## Status legend

- `[ ]` not started
- `[~]` partially implemented or design-only
- `[x]` implemented and locally validated

## Current priority tracks

Current short-term scope: **connection/runtime identity and lifecycle**,
then the remaining concurrency hardening. The type-coverage push is
largely complete for the implemented plan matrix; do not add new public
execution modes until the runtime identity, release, and stale-state
issues are fixed.

- **P0 release gates**: package checks, r-universe/oldrelease/wasm
  status, and README/API text that prevents users from misunderstanding
  current semantics.
- **P0 connection identity/lifecycle**: replace SEXP-address R-side
  keys, define explicit runtime release, and make repeated
  connect/disconnect safe.
- **P1 correctness hardening**: no-fallback tests, queue timeout/join
  behavior, main-R-thread resource release, plan-transition tests, and
  GC/lifetime tests.
- **P2 observability**: richer queue counters, counter reset, native/R
  state cross-checks, and generated/native counter-field consistency.
- **P3 future performance/backends**: owned chunk boundaries, persistent
  worker transports, and Arrow IPC overhead reduction.

## Current baseline

- Current pushed baseline when this tracker was refreshed:
  `454441b Tighten README thread wording`.

- Recent implementation commits to preserve:

  - `7d054cf Cooperatively batch RIPC callbacks`
  - `5738c45 Refresh Rducks surfaces on extension reload`
  - `49146d2 Document unstable DuckDB extension API usage`
  - `eeb9ee3 Protect RC scalar return values across checks`
  - `46d947e Harden Rducks runtime refresh and thread checks`
  - `7f4b71e Clarify Arrow conversion and in-process queue docs`
  - `454441b Tighten README thread wording`

- Latest local validation after native/runtime hardening:

  - `R CMD INSTALL .` OK
  - `make test` OK: 528 tinytest results
  - README rendered from `README.Rmd` for the latest documentation
    commits

- R-universe may lag GitHub pushes. Check the API before assuming
  oldrelease or wasm results include the latest commits:

  ``` sh
  python3 - <<'PY'
  import json, urllib.request
  obj = json.load(urllib.request.urlopen('https://sounkou-bioinfo.r-universe.dev/api/packages/Rducks'))
  print(obj.get('RemoteSha'), obj.get('_status'), obj.get('_buildurl'))
  PY
  ```

## Non-negotiable semantics and constraints

These are guardrails, not TODO checkboxes.

- Keep DuckDB Arrow C Data + nanoarrow as the canonical in-process
  marshalling layer.
- Use Arrow IPC only for explicit serialized/out-of-process transport.
- Do not silently fall back between plans:
  - no hidden `arrow_c -> arrow_r`
  - no hidden `arrow_ipc -> serialize()`
  - no hidden `multiprocess_parallel -> in-process`
  - no hidden vectorized chunk call -\> scalar row loop
- Keep all R API calls on the recorded main R thread for same-process
  execution.
- Do not use DuckDB C++ APIs, patch `duckdb` R, use `con@conn_ref`, add
  a package-side queue/pump, or rely on hidden progress callbacks.
- Same-process concurrency target is no deadlocks and explicit errors on
  unsupported paths; it is not a promise of faster R evaluation.
- Keep `arrow_lossless_conversion=true` documented: it affects
  DuckDB-to-Arrow conversion at the Rducks boundary, not stored DuckDB
  values or SQL semantics.

## Implemented plan matrix to preserve

| Plan | Scalar mode | Vectorized mode | Notes |
|----|----|----|----|
| `arrow_r + serial` | implemented | implemented | semantic reference |
| `arrow_r + inproc_concurrent` | implemented | implemented | queued same-process path; R API work stays on the recorded main R thread |
| `arrow_c + serial` | implemented | implemented | native scalar evaluator and `RCV` vectorized chunk evaluator |
| `arrow_c + inproc_concurrent` | implemented | implemented | queued same-process path with `arrow_c` marshalling; R callbacks still run on the recorded main R thread |
| `arrow_ipc + multiprocess_parallel` | implemented | implemented | Future-backed Arrow IPC provider, evaluator `RIPC` |

`arrow_c` vectorized mode uses the `RCV` native evaluator token. The
current `arrow_ipc + multiprocess_parallel` path uses generic `future`
backends and Arrow IPC payloads. Scalar mode loops over logical rows
inside the worker; vectorized mode calls the R function once per chunk.
The provider splits submit and collect phases so queued chunk futures
can overlap when DuckDB provides multiple concurrent UDF callbacks.

## Recently completed hardening

Native RIPC submit/collect batching and counters.

Removed the rejected `rducks_query_stream()` direction.

Extension reload refreshes SQL surfaces when needed.

Programmatic unstable DuckDB C extension ABI scanner and README table.

RC scalar return values protected across return checks.

POSIX thread identity now uses `pthread_equal()` instead of comparing
serialized `pthread_t` bytes; Windows keeps `GetCurrentThreadId()`.

Runtime refresh now clears stale UDF registry bookkeeping and configures
the refreshed extension-owned connection with
`arrow_lossless_conversion=true`.

RC direct input view allocation uses `R_alloc()` instead of `calloc()`
to avoid leaks on R longjmp paths.

Queue/global-runtime lock discipline documented.

README documents `arrow_lossless_conversion=true` and uses a real DuckDB
table-scan diagnostic for in-process queued execution.

## P0: connection identity and lifecycle

**Replace SEXP-address keying for R-side connection state.**

- Current risk: `rducks_connection_key()` uses
  `.Call(RDUCKS_sexp_addr, con)`. R can reuse freed SEXP addresses, so
  `.rducks_state$connection_plans` and `.rducks_state$registrations` can
  collide with dead connections.
- Target: C extension exposes an opaque Rducks runtime/connection token,
  for example `SELECT rducks_connection_token()`, based on an
  Rducks-owned monotonic runtime id/generation rather than a raw R SEXP
  address.
- R side uses that token as the key for plan and registration stores.
- Decide whether the token is attached as a hidden attribute or via a
  `rducks_connection` subclass/wrapper; document that users should keep
  the object returned by
  [`rducks_enable()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable.md)
  if the API changes.
- Acceptance: repeated `dbConnect()` /
  [`rducks_enable()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable.md)
  / register / `dbDisconnect()` loops cannot make a new connection see
  stale plans or UDF registration metadata.

**Add explicit Rducks runtime release.**

- Target API: `rducks_release(con)` is idempotent.
- Native work: release or invalidate the runtime entry, drain/reset
  queue state, disconnect extension-owned DuckDB connection, and detach
  UDF registry bookkeeping. Do not call R API from off-main destructors.
- R work: remove the connection token from
  `.rducks_state$connection_plans` and `.rducks_state$registrations`.
- Best-effort fallback: an Rducks-owned external pointer/finalizer may
  call a non-SQL `.Call` cleanup path, but finalizers must not call
  DBI/SQL.
- Acceptance: repeated release/disconnect is harmless and does not leave
  stale R-side state for subsequent connections.

**Define `dbDisconnect()` integration.**

- Preferred design if subclassing/wrapping is adopted: a
  `dbDisconnect()` method for `rducks_connection` calls
  `rducks_release(conn)` before delegating to duckdb-r.
- If plain attributes remain the implementation, document the explicit
  `rducks_release(con); DBI::dbDisconnect(con)` pattern and add tests.

**Main-thread release queue for preserved R objects.**

- Current behavior: metadata destroyed off the main R thread avoids
  `R_ReleaseObject()`, intentionally leaking preserved functions rather
  than calling R API unsafely.
- Target: deterministic release on the recorded main R thread, likely
  keyed by the same opaque runtime token and UDF name.

## P0/P1: release and infrastructure follow-up

**P0** Watch R-universe until it builds the current `main` commit.

- Acceptance: R-universe API `RemoteSha` matches a current `main` commit
  and status is success.
- If oldrelease fails, confirm `Depends: R (>= 4.3)` is present in the
  built source package.
- If wasm fails, fetch logs and update `configure` /
  `Dockerfile.webr-test`.

**P1** Add a CI/webR wasm build job or documented manual trigger.

- Acceptance: it runs `rwasm::build()` in `ghcr.io/r-wasm/webr:main` and
  verifies the `.tgz` artifact exists.

**P0** Add R 4.3 validation.

- Acceptance: package installs and core tests run under R 4.3.x,
  matching the lowered dependency floor.

## Execution-plan and introspection work

Add per-UDF execution introspection.

- Implemented:
  [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)
  plus native `rducks_udf_stat()` counters.
- Current counters include dispatch, queue, evaluator, and RIPC batching
  counters.

Add
[`rducks_list_udfs()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_list_udfs.md)
connection-level registry view.

- Caveat until P0 identity work is done: the R-side registry is keyed by
  the unsafe SEXP-address key.

\[~\] **P1** Extend no-fallback tests to generated matrix cases.

- Current status: generated vectorized conformance cases assert the
  expected `arrow_r`/`arrow_c` counter moved and the other marshalling
  counter stayed zero.
- Remaining acceptance: extend the same counter assertions to scalar
  generated cases where native counters are meaningful.

**P0** Decide and document whether marshalling is a registration-time
snapshot or a query-time session choice.

- Current behavior: active plan at
  [`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md)
  chooses native evaluator (`R`/`RC`/`RCV`/`RIPC`) stored in DuckDB UDF
  metadata; later plan changes alter concurrency backend but do not
  retarget an already registered UDF’s marshalling.
- Needed clarification: either make this the explicit public semantic or
  implement true query-time marshalling dispatch.

**P1** Define duplicate-registration and UDF lifecycle semantics.

- Questions: should duplicate name/signature registrations error,
  overwrite, or create overloads? Is `rducks_unregister()`
  feasible/desirable? What is guaranteed after connection close?
- Acceptance: tests and docs cover duplicate registration, dropped
  R-side registration objects, and connection teardown.

**P1** Handle partial failures in
[`rducks_set_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_set_execution_plan.md).

- Current drift: thread settings may be changed before native backend
  setup fails, while the R-side plan cache remains old.
- Acceptance: either roll back thread settings on failure or document
  the partial-application contract and test the error path.

**P2** Add counter reset support for benchmarks/tests.

- Acceptance: reset one UDF or all UDF counters without unregistering
  the UDF.

**P2** Expose native current-backend/plan diagnostics.

- Acceptance: R-side
  [`rducks_current_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_current_execution_plan.md)
  can be cross-checked against native backend state to detect stale
  R-side connection-plan storage.

**P2** Mark or skip missing R-side registration records.

- Current behavior: `rducks_explain_udf_row()` can return rows with `NA`
  metadata when the R-side record is absent.
- Acceptance: either add `rducks_managed = TRUE/FALSE` or make
  [`rducks_list_udfs()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_list_udfs.md)
  omit rows without current-session Rducks metadata.

**P2** Generate/discover native UDF stat fields instead of mirroring
names by hand in R and C.

- Acceptance: adding a native counter does not require manually
  synchronizing an R character vector with a C `strcmp` cascade.

## Same-process concurrency safety

\[~\] Extension-owned in-process queue is implemented.

- Current status: queue self-test and queued scalar/vectorized tests
  pass.
- Known limitation: queued UDF requests currently borrow
  `duckdb_data_chunk` / `duckdb_vector` pointers synchronously.

**P1** Fix unbounded waits after a request starts running.

- Current issue: timeout policy applies while a request is `PENDING`; a
  `RUNNING` request can still wait indefinitely.
- Related issue: `rducks_queue_submit_scalar_via_worker_on_main()` can
  still fall through to an infinite `pthread_join()`/Windows wait.

**P1** Add stress tests for no-deadlock behavior.

- Acceptance: repeated queued UDF calls with multiple DuckDB threads
  either complete or fail with the documented timeout, never hang.

**P2** Make queue timeout policy explicit and configurable if needed.

- Current constants: `RDUCKS_QUEUE_WAIT_MS`,
  `RDUCKS_QUEUE_TIMEOUT_TICKS`.
- Acceptance: docs and tests cover timeout error text and counter
  increments.

**P2** Add runtime-wide queue pressure counters.

- Current
  [`rducks_inproc_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_inproc_stats.md)
  exposes only `submitted`, `executed`, and `timeouts`; per-UDF pending
  counters exist in
  [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md).
- Acceptance:
  [`rducks_inproc_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_inproc_stats.md)
  includes runtime-wide current/max pending counts or clearly points
  users to per-UDF diagnostics.

**P3** Implement an owned input snapshot for worker-originating chunk
requests.

- Acceptance: worker request can outlive the original DuckDB callback
  frame without borrowed input pointers.

**P3** Implement owned result payloads plus safe writeback.

- Acceptance: main R thread fills owned result memory; DuckDB output
  writeback is performed at a safe boundary with no R API on worker
  threads.

## Arrow IPC / multiprocess work

\[~\] `arrow_ipc + multiprocess_parallel` scalar and vectorized UDF
paths are implemented through generic `future` backends.

- Current implementation uses Arrow IPC bytes for chunk tasks/results
  and cooperatively batches queued callbacks into grouped collection
  waves.
- Known limitations: cheap/no-op UDFs are dominated by Arrow IPC/Future
  overhead; small query shapes do not always provide enough DuckDB
  parallelism to show overlap.

**P1** Fix cooperative queue counter under-reporting.

- Current issue: cooperative RIPC path can make runtime-wide
  `submitted/executed` counters look lower than per-UDF queued chunk
  counts.

**P2** Reduce Arrow IPC/Future overhead for cheap UDFs.

- Acceptance: benchmarked improvement without hidden fallback or fake
  results.

**P2** Improve batching beyond small waves for typical DuckDB physical
scans.

**P3** Specify a future persistent worker/request envelope.

- Include UDF id/name, signature, mode, null/error semantics, chunk
  sequence, timeout, cancellation token, and schema metadata.

**P3** Decide worker transport beyond generic `future` if needed.

- Constraint: hot data path remains Arrow IPC bytes; no R
  [`serialize()`](https://rdrr.io/r/base/serialize.html) /
  [`unserialize()`](https://rdrr.io/r/base/serialize.html) fallback for
  chunk payloads.
- Constraint: do not link against uninstalled `nanonext.so` internals.

**P3** Implement persistent worker startup/shutdown and function
distribution if generic `future` is not enough.

**P3** Implement backpressure, cancellation, and error propagation for a
persistent worker transport.

## Native Arrow / `arrow_c` work

Scalar `arrow_c` direct-buffer evaluator for implemented types.

Native `arrow_c + vectorized` as a first-class implementation.

- Implemented combinations:
  - `arrow_c + serial + vectorized`
  - `arrow_c + inproc_concurrent + vectorized`
- Current native evaluator token: `RCV`.

**P1** Add focused tests for every `arrow_c` fallback-to-`arrow_r` risk.

- Acceptance:
  [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)
  shows `arrow_c_chunks > 0` and `arrow_r_chunks == 0` for all supported
  `arrow_c` cases.

**P1** Defensively clear Arrow C Data release callbacks on conversion
failure.

- Current issue: some failure paths do not defensively zero
  `array->release`.

**P2** Re-audit Arrow validity handling.

- Current concern: `rducks_arrow_validity()` relies on nanoarrow/DuckDB
  validity-buffer behavior that should be made explicit or guarded.

**P3** Split `arrow_c` into worker-safe native phases and R-thread
phases.

- Acceptance: a pure-native phase can run without touching SEXPs or R
  APIs; any R API phase is explicitly routed to the recorded main R
  thread.

## R API, protection, and longjmp safety

RC scalar return values protected across checks.

RC direct input views use `R_alloc()` to avoid leaking on R longjmp.

**P1** Audit remaining `Rf_*` longjmp paths in generated/native
wrappers.

- Acceptance: no heap allocation or borrowed-pointer state is leaked
  across `Rf_error()` / longjmp paths; use `R_alloc()` or
  `R_UnwindProtect()` where appropriate.

**P1** Add GC/lifetime tests.

- Drop R registration objects, run
  [`gc()`](https://rdrr.io/r/base/gc.html), then call the DuckDB UDF.
- Close/release connections after registrations and confirm no crashes
  or stale R-side metadata.

## Wasm / webR work

Make `configure` wasm-aware enough for `rwasm::build()`.

**P1** Add a webR runtime smoke test, not just a build test.

- Acceptance: install the built `.tgz` in webR and run at least package
  load, native helper calls, and a minimal DuckDB extension load if
  supported.

**P0** Document wasm support level.

- Clarify whether Rducks on wasm is build-only, package-load smoke
  tested, or full DuckDB-extension runtime tested.

**P1** Keep wasm configure behavior aligned with r-universe/rwasm.

- Acceptance: no host `libR.so` link attempt and extension entrypoint
  export remains present.

## Potential table-function / view work

This is a parking lot unless promoted into scope. It is motivated by how
the `duckdb` R package registers R data frames: it creates a view over a
table function that lazily scans R vector memory.

**P3** Decide whether Rducks should expose any data-source registration
API.

- Default position: Rducks remains focused on R UDF registration unless
  there is a clear UDF-related use case.

**P3** Prototype a C-API-only table-function + `CREATE TEMP VIEW`
pattern.

- Acceptance: uses `duckdb_register_table_function()` and
  `duckdb_query()` with `CREATE TEMP VIEW ... AS SELECT * FROM ...`; no
  DuckDB C++ relation API.

**P3** Document copy semantics if data-source registration enters scope.

## Test backlog

**P1** Add repeated connect/disconnect/release tests.

- Acceptance: runtime registry and R-side stores do not use stale
  database handles, stale connection-plan state, or stale registration
  records.

**P1** Add plan-transition tests.

- Register in `arrow_r`, switch to `arrow_c`, and prove existing UDF
  marshalling remains as documented.
- Register in `arrow_c`, enable/disable inproc, and prove only
  concurrency counters change.

**P1** Add vectorized edge tests for chunk boundaries.

- Empty chunks if DuckDB can produce them, all-NULL chunks, partial NULL
  chunks, and multi-chunk inputs with strict return length checks.

**P1** Add error/default NULL tests for each implemented plan.

- Acceptance: `exception_handling = "return_null"` and `"rethrow"`
  behave the same across supported plan/mode combinations.

**P2** Add native sanitizer or valgrind workflow if feasible.

- Acceptance: at least extension build/load and a representative UDF
  suite run under memory checking on Linux.

## Semantic documentation backlog

Note: `docs/` is ignored in this repository; use `git add -f docs/...`
for docs that should be committed.

README documents `arrow_lossless_conversion=true`.

README quick start shows a zero-argument scalar UDF with `args = NULL`.

README in-process queue example uses a DuckDB table scan with
`threads = 4, external_threads = 1`, reports main-thread vs
worker-thread probe rows, and states that speedup should not be
inferred.

**P0** Update `docs/EXECUTION_PLANS.md` with:

- implemented matrix above
- no-fallback principle
- current registration-time vs query-time marshalling behavior
- [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)
  counters and examples

**P1** Replace remaining imprecise internal/docs wording about R-thread
execution with “recorded main R thread” where that is what is meant.

**P1** Keep
[`rducks_mode_semantics()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_mode_semantics.md)
aligned with docs and tests.

**P1** Publish an explicit type/mode/plan support table.

- Acceptance: one table states type support for scalar/vectorized,
  `arrow_r`/`arrow_c`, NULL handling, and copy/borrow expectations.

**P0** Clarify vectorized mode semantics.

- One R call per DuckDB chunk, strict return length, default vs special
  NULL handling, no scalar-row-loop fallback.

**P0** Clarify side-effect semantics.

- `side_effects = TRUE` maps to DuckDB volatile behavior; it does not
  change R thread or queue semantics.

**P0** Clarify ownership/lifetime semantics.

- Preserved R functions, per-connection/runtime registry, external
  pointer and nanoarrow object lifetime, and limitations around off-main
  destruction.

## Release hygiene

Keep `NEWS.md` user-facing; do not mention internal agent instructions.

Do not manually edit generated `.Rd` files; update roxygen comments and
run `make rd`.

Before release-like pushes, run:

``` sh
make install
make test
Rscript tools/run_generated_marshalling_matrix.R
make check
```

Remove generated artifacts before committing:

- `Rducks_*.tar.gz`
- `Rducks_*.tgz`
- `Rducks.Rcheck/`
- `inst/rducks_extension/build/`
