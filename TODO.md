# Rducks TODO

This file tracks implementation work, tests, and semantic clarifications that are
not yet complete. It is intentionally development-facing; user-facing release
notes stay in `NEWS.md`.

## Status legend

- `[ ]` not started
- `[~]` partially implemented or design-only
- `[x]` implemented and locally validated

## Current baseline

- Latest pushed baseline before this TODO: `cfa8e2c Add UDF execution introspection`.
- Locally validated at that baseline:
  - `make test` OK: 457 tinytest results
  - `Rscript tools/run_generated_marshalling_matrix.R` OK: 472 cases
  - `make check` OK
  - local `ghcr.io/r-wasm/webr:main` + `rwasm::build()` OK
- R-universe may lag GitHub pushes. Check the API before assuming oldrelease or
  wasm results include the latest commits:

  ```sh
  python3 - <<'PY'
  import json, urllib.request
  obj = json.load(urllib.request.urlopen('https://sounkou-bioinfo.r-universe.dev/api/packages/Rducks'))
  print(obj.get('RemoteSha'), obj.get('_status'), obj.get('_buildurl'))
  PY
  ```

## Non-negotiable semantics and constraints

- [ ] Keep DuckDB Arrow C Data + nanoarrow as the canonical in-process
  marshalling layer.
- [ ] Use Arrow IPC only for explicit serialized/out-of-process transport.
- [ ] Do not silently fall back between plans:
  - no hidden `arrow_c -> arrow_r`
  - no hidden `arrow_ipc -> serialize()`
  - no hidden `multiprocess_parallel -> in-process`
  - no hidden vectorized chunk call -> scalar row loop
- [ ] Keep all R API calls on the recorded main R thread for same-process
  execution.
- [ ] Do not use DuckDB C++ APIs, patch `duckdb` R, use `con@conn_ref`, add a
  package-side queue/pump, or rely on hidden progress callbacks.
- [ ] Same-process concurrency target is no deadlocks and explicit errors on
  unsupported paths; it is not a promise of faster R evaluation.

## Implemented plan matrix to preserve

| Plan | Scalar mode | Vectorized mode | Notes |
| --- | --- | --- | --- |
| `arrow_r + serial` | implemented | implemented | semantic reference |
| `arrow_r + inproc_concurrent` | implemented | implemented | queued same-process path |
| `arrow_c + serial` | implemented | rejected | direct native scalar evaluator |
| `arrow_c + inproc_concurrent` | implemented | rejected | queued same-process path |
| `arrow_ipc + multiprocess_parallel` | design-only | design-only | future out-of-process transport |

## Immediate release / infrastructure follow-up

- [ ] Watch R-universe until it builds commits `d07770e` and `cfa8e2c` or later.
  - Acceptance: R-universe API `RemoteSha` matches a current `main` commit and
    status is success.
  - If oldrelease fails, confirm `Depends: R (>= 4.3)` is present in the built
    source package.
  - If wasm fails, fetch logs and update `configure` / `Dockerfile.webr-test`.
- [ ] Add or verify CI coverage for the generated marshalling matrix.
  - Existing workflow: `.github/workflows/generated-marshalling-matrix.yaml`.
  - Acceptance: push/PR run executes all 472 generated cases or an explicitly
    configured subset and uploads enough logs for failed cases.
- [ ] Add a CI/webR wasm build job or documented manual trigger.
  - Acceptance: it runs `rwasm::build()` in `ghcr.io/r-wasm/webr:main` and
    verifies the `.tgz` artifact exists.

## Execution-plan and introspection work

- [x] Add per-UDF execution introspection.
  - Implemented: `rducks_explain_udf()` plus native `rducks_udf_stat()` counters.
  - Current counters: `dispatch_chunks`, `dispatch_rows`, `direct_chunks`,
    `queued_chunks`, `arrow_r_chunks`, `arrow_c_chunks`.
- [ ] Extend no-fallback tests to generated matrix cases.
  - Acceptance: every generated `arrow_r`/`arrow_c` conformance case asserts the
    expected native counter moved and the other marshalling counter stayed zero.
- [ ] Decide and document whether marshalling is a registration-time snapshot or
  a query-time session choice.
  - Current behavior: active plan at `rducks_register()` chooses native evaluator
    (`R`/`RC`) stored in DuckDB UDF metadata; later plan changes alter
    concurrency backend but do not retarget an already registered UDF's
    marshalling.
  - Needed clarification: either make this the explicit public semantic or
    implement true query-time marshalling dispatch.
- [ ] Add `rducks_list_udfs()` or equivalent connection-level registry view.
  - Acceptance: returns all UDFs registered through `rducks_register()` on the
    connection with mode, signature, plan snapshot, and counters.
- [ ] Add counter reset support for benchmarks/tests.
  - Acceptance: reset one UDF or all UDF counters without unregistering the UDF.
- [ ] Expose native current-backend/plan diagnostics.
  - Acceptance: R-side `rducks_current_execution_plan()` can be cross-checked
    against native backend state to detect stale R-side connection-plan storage.

## Same-process concurrency safety

- [~] Extension-owned in-process queue is implemented.
  - Current status: queue self-test and queued scalar/vectorized tests pass.
  - Known limitation: queued scalar requests currently borrow `duckdb_data_chunk`
    / `duckdb_vector` pointers synchronously.
- [ ] Implement an owned input snapshot for worker-originating chunk requests.
  - Acceptance: worker request can outlive the original DuckDB callback frame
    without borrowed input pointers.
- [ ] Implement owned result payloads plus safe writeback.
  - Acceptance: main R lane fills owned result memory; DuckDB output writeback is
    performed at a safe boundary with no R API on worker threads.
- [ ] Implement a main-thread release queue for R-owned resources.
  - Current issue: metadata destroyed off-main avoids `R_ReleaseObject()`, which
    can leak preserved functions by design.
  - Acceptance: all `R_PreserveObject()` calls have deterministic main-thread
    release or documented lifetime limits.
- [ ] Add stress tests for no-deadlock behavior.
  - Acceptance: repeated queued UDF calls with multiple DuckDB threads either
    complete or fail with the documented timeout, never hang.
- [ ] Make queue timeout policy explicit and configurable if needed.
  - Current constants: `RDUCKS_QUEUE_WAIT_MS`, `RDUCKS_QUEUE_TIMEOUT_TICKS`.
  - Acceptance: docs and tests cover timeout error text and counter increments.

## Native `arrow_c` work

- [x] Scalar `arrow_c` direct-buffer evaluator for implemented types.
- [ ] Design native `arrow_c + vectorized` as a first-class implementation.
  - Do not enable by removing guards.
  - Acceptance: vectorized native path preserves chunk-call semantics, NULL
    semantics, exotic/composite values, and no-fallback counters.
- [ ] Split `arrow_c` into worker-safe native phases and R-thread phases.
  - Acceptance: a pure-native phase can run without touching SEXPs or R APIs;
    any R API phase is explicitly routed to the main R lane.
- [ ] Add focused tests for every `arrow_c` fallback-to-arrow-R risk.
  - Acceptance: `rducks_explain_udf()` shows `arrow_c_chunks > 0` and
    `arrow_r_chunks == 0` for all supported `arrow_c` cases.

## Arrow IPC / multiprocess work

- [ ] Specify the out-of-process request envelope.
  - Include UDF id/name, signature, mode, null/error semantics, chunk sequence,
    timeout, cancellation token, and schema metadata.
- [ ] Keep Arrow IPC hot-path payloads as Arrow IPC bytes.
  - Acceptance: hot data path has tests or instrumentation proving it does not
    use R `serialize()` / `unserialize()`.
- [ ] Decide worker transport for the first MVP.
  - Option A: mirai APIs for process management, accepting R serialization only
    for metadata/control if unavoidable.
  - Option B: custom raw nanonext/NNG/socket protocol for raw Arrow IPC.
  - Constraint: do not link against uninstalled `nanonext.so` internals.
- [ ] Implement worker startup/shutdown and function distribution.
  - Acceptance: workers can load required package code, bind function metadata,
    and report initialization errors deterministically.
- [ ] Implement backpressure, cancellation, and error propagation.
  - Acceptance: worker failure returns a DuckDB error or NULL according to the
    registered `exception_handling` semantics, without leaking jobs.
- [ ] Add conformance tests against `arrow_r + serial`.
  - Acceptance: scalar and vectorized results match the reference for supported
    types and NULL/error modes.

## Wasm / webR work

- [x] Make `configure` wasm-aware enough for `rwasm::build()`.
- [ ] Add a webR runtime smoke test, not just a build test.
  - Acceptance: install the built `.tgz` in webR and run at least package load,
    native helper calls, and a minimal DuckDB extension load if supported.
- [ ] Document wasm support level.
  - Clarify whether Rducks on wasm is build-only, package-load smoke tested, or
    full DuckDB-extension runtime tested.
- [ ] Keep wasm configure behavior aligned with r-universe/rwasm.
  - Acceptance: no host `libR.so` link attempt and extension entrypoint export
    remains present.

## Test backlog

- [ ] Add GC/lifetime tests.
  - Drop R registration objects, run `gc()`, then call the DuckDB UDF.
  - Close connections after registrations and confirm no crashes.
- [ ] Add repeated connect/disconnect tests.
  - Acceptance: runtime registry and per-UDF registry do not use stale database
    handles or stale connection-plan state.
- [ ] Add plan-transition tests.
  - Register in `arrow_r`, switch to `arrow_c`, and prove existing UDF
    marshalling remains as documented.
  - Register in `arrow_c`, enable/disable inproc, and prove only concurrency
    counters change.
- [ ] Add vectorized edge tests for chunk boundaries.
  - Empty chunks if DuckDB can produce them, all-NULL chunks, partial NULL chunks,
    and multi-chunk inputs with strict return length checks.
- [ ] Add error/default NULL tests for each implemented plan.
  - Acceptance: `exception_handling = "return_null"` and `"rethrow"` behave the
    same across supported plan/mode combinations.
- [ ] Add native sanitizer or valgrind workflow if feasible.
  - Acceptance: at least extension build/load and a representative UDF suite run
    under memory checking on Linux.
- [ ] Add R 4.3 validation.
  - Acceptance: package installs and core tests run under R 4.3.x, matching the
    lowered dependency floor.

## Semantic documentation backlog

- [ ] Update `docs/EXECUTION_PLANS.md` with:
  - implemented matrix above
  - no-fallback principle
  - current registration-time vs query-time marshalling behavior
  - `rducks_explain_udf()` counters and examples
- [ ] Update README with a short `rducks_explain_udf()` example after API
  stabilizes.
- [ ] Keep `rducks_mode_semantics()` aligned with docs and tests.
- [ ] Publish an explicit type/mode/plan support table.
  - Acceptance: one table states type support for scalar/vectorized,
    `arrow_r`/`arrow_c`, NULL handling, and copy/borrow expectations.
- [ ] Clarify vectorized mode semantics.
  - One R call per DuckDB chunk, strict return length, default vs special NULL
    handling, no scalar-row-loop fallback.
- [ ] Clarify side-effect semantics.
  - `side_effects = TRUE` maps to DuckDB volatile behavior; it does not change R
    thread or queue semantics.
- [ ] Clarify ownership/lifetime semantics.
  - Preserved R functions, per-connection/runtime registry, external pointer and
    nanoarrow object lifetime, and limitations around off-main destruction.

## Release hygiene

- [ ] Keep `NEWS.md` user-facing; do not mention internal agent instructions.
- [ ] Do not manually edit generated `.Rd` files; update roxygen comments and
  run `make rd`.
- [ ] Before release-like pushes, run:

  ```sh
  make install
  make test
  Rscript tools/run_generated_marshalling_matrix.R
  make check
  ```

- [ ] Remove generated artifacts before committing:
  - `Rducks_*.tar.gz`
  - `Rducks_*.tgz`
  - `Rducks.Rcheck/`
  - `inst/rducks_extension/build/`
