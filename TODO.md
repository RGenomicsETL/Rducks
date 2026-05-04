# Rducks TODO

This file tracks implementation work, tests, and semantic clarifications
that are not yet complete. It is intentionally development-facing;
user-facing release notes stay in `NEWS.md`.

## Status legend

- `[ ]` not started
- `[~]` partially implemented or design-only
- `[x]` implemented and locally validated

## Priority lanes

- **P0 release gates**: r-universe/oldrelease/wasm status, package
  checks, and semantic text that prevents users from misunderstanding
  the current API.
- **P1 correctness hardening**: no-fallback tests, plan-transition
  tests, lifetime/GC tests, and native/R-thread boundary tests.
- **P2 observability and ergonomics**: listing UDFs, counter reset,
  README/docs examples, and richer diagnostics.
- **P3 future backends**: owned queued boundaries, native vectorized
  `arrow_c`, and Arrow IPC multiprocess execution.

## Current baseline

- Code baseline validated before adding this tracker:
  `cfa8e2c Add UDF execution introspection`.

- Tracker commit: `06d6f3d Add implementation TODO tracker`.

- Locally validated at the code baseline:

  - `make test` OK: 457 tinytest results
  - `Rscript tools/run_generated_marshalling_matrix.R` OK: 472 cases
  - `make check` OK
  - local `ghcr.io/r-wasm/webr:main` + `rwasm::build()` OK

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

## Implemented plan matrix to preserve

| Plan | Scalar mode | Vectorized mode | Notes |
|----|----|----|----|
| `arrow_r + serial` | implemented | implemented | semantic reference |
| `arrow_r + inproc_concurrent` | implemented | implemented | queued same-process path |
| `arrow_c + serial` | implemented | rejected | direct native scalar evaluator |
| `arrow_c + inproc_concurrent` | implemented | rejected | queued same-process path |
| `arrow_ipc + multiprocess_parallel` | design-only | design-only | future out-of-process transport |

## Immediate release / infrastructure follow-up

**P0** Watch R-universe until it builds commit `06d6f3d` or later.

- Acceptance: R-universe API `RemoteSha` matches a current `main` commit
  and status is success.
- If oldrelease fails, confirm `Depends: R (>= 4.3)` is present in the
  built source package.
- If wasm fails, fetch logs and update `configure` /
  `Dockerfile.webr-test`.

**P1** Add or verify CI coverage for the generated marshalling matrix.

- Existing workflow:
  `.github/workflows/generated-marshalling-matrix.yaml`.
- Acceptance: push/PR run executes all 472 generated cases or an
  explicitly configured subset and uploads enough logs for failed cases.

**P1** Add a CI/webR wasm build job or documented manual trigger.

- Acceptance: it runs `rwasm::build()` in `ghcr.io/r-wasm/webr:main` and
  verifies the `.tgz` artifact exists.

## Execution-plan and introspection work

Add per-UDF execution introspection.

- Implemented:
  [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)
  plus native `rducks_udf_stat()` counters.
- Current counters: `dispatch_chunks`, `dispatch_rows`, `direct_chunks`,
  `queued_chunks`, `arrow_r_chunks`, `arrow_c_chunks`.

**P1** Extend no-fallback tests to generated matrix cases.

- Acceptance: every generated `arrow_r`/`arrow_c` conformance case
  asserts the expected native counter moved and the other marshalling
  counter stayed zero.

**P0** Decide and document whether marshalling is a registration-time
snapshot or a query-time session choice.

- Current behavior: active plan at
  [`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md)
  chooses native evaluator (`R`/`RC`) stored in DuckDB UDF metadata;
  later plan changes alter concurrency backend but do not retarget an
  already registered UDF’s marshalling.
- Needed clarification: either make this the explicit public semantic or
  implement true query-time marshalling dispatch.

**P2** Add `rducks_list_udfs()` or equivalent connection-level registry
view.

- Acceptance: returns all UDFs registered through
  [`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md)
  on the connection with mode, signature, plan snapshot, and counters.

**P2** Add counter reset support for benchmarks/tests.

- Acceptance: reset one UDF or all UDF counters without unregistering
  the UDF.

**P2** Expose native current-backend/plan diagnostics.

- Acceptance: R-side
  [`rducks_current_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_current_execution_plan.md)
  can be cross-checked against native backend state to detect stale
  R-side connection-plan storage.

**P1** Define duplicate-registration and UDF lifecycle semantics.

- Questions: should duplicate name/signature registrations error,
  overwrite, or create overloads? Is `rducks_unregister()`
  feasible/desirable? What is guaranteed after connection close?
- Acceptance: tests and docs cover duplicate registration, dropped
  R-side registration objects, and connection teardown.

## Same-process concurrency safety

\[~\] Extension-owned in-process queue is implemented.

- Current status: queue self-test and queued scalar/vectorized tests
  pass.
- Known limitation: queued UDF requests currently borrow
  `duckdb_data_chunk` / `duckdb_vector` pointers synchronously.

**P3** Implement an owned input snapshot for worker-originating chunk
requests.

- Acceptance: worker request can outlive the original DuckDB callback
  frame without borrowed input pointers.

**P3** Implement owned result payloads plus safe writeback.

- Acceptance: main R lane fills owned result memory; DuckDB output
  writeback is performed at a safe boundary with no R API on worker
  threads.

**P1** Implement a main-thread release queue for R-owned resources.

- Current issue: metadata destroyed off-main avoids `R_ReleaseObject()`,
  which can leak preserved functions by design.
- Acceptance: all `R_PreserveObject()` calls have deterministic
  main-thread release or documented lifetime limits.

**P1** Add stress tests for no-deadlock behavior.

- Acceptance: repeated queued UDF calls with multiple DuckDB threads
  either complete or fail with the documented timeout, never hang.

**P2** Make queue timeout policy explicit and configurable if needed.

- Current constants: `RDUCKS_QUEUE_WAIT_MS`,
  `RDUCKS_QUEUE_TIMEOUT_TICKS`.
- Acceptance: docs and tests cover timeout error text and counter
  increments.

## Native `arrow_c` work

Scalar `arrow_c` direct-buffer evaluator for implemented types.

**P3** Design native `arrow_c + vectorized` as a first-class
implementation.

- Do not enable by removing guards.
- Acceptance: vectorized native path preserves chunk-call semantics,
  NULL semantics, exotic/composite values, and no-fallback counters.

**P3** Split `arrow_c` into worker-safe native phases and R-thread
phases.

- Acceptance: a pure-native phase can run without touching SEXPs or R
  APIs; any R API phase is explicitly routed to the main R lane.

**P1** Add focused tests for every `arrow_c` fallback-to-arrow-R risk.

- Acceptance:
  [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)
  shows `arrow_c_chunks > 0` and `arrow_r_chunks == 0` for all supported
  `arrow_c` cases.

## Arrow IPC / multiprocess work

**P3** Specify the out-of-process request envelope.

- Include UDF id/name, signature, mode, null/error semantics, chunk
  sequence, timeout, cancellation token, and schema metadata.

**P3** Keep Arrow IPC hot-path payloads as Arrow IPC bytes.

- Acceptance: hot data path has tests or instrumentation proving it does
  not use R [`serialize()`](https://rdrr.io/r/base/serialize.html) /
  [`unserialize()`](https://rdrr.io/r/base/serialize.html).

**P3** Decide worker transport for the first MVP.

- Option A: mirai APIs for process management, accepting R serialization
  only for metadata/control if unavoidable.
- Option B: custom raw nanonext/NNG/socket protocol for raw Arrow IPC.
- Constraint: do not link against uninstalled `nanonext.so` internals.

**P3** Implement worker startup/shutdown and function distribution.

- Acceptance: workers can load required package code, bind function
  metadata, and report initialization errors deterministically.

**P3** Implement backpressure, cancellation, and error propagation.

- Acceptance: worker failure returns a DuckDB error or NULL according to
  the registered `exception_handling` semantics, without leaking jobs.

**P3** Add conformance tests against `arrow_r + serial`.

- Acceptance: scalar and vectorized results match the reference for
  supported types and NULL/error modes.

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

- Acceptance: distinguish zero-copy registration/lazy scan from
  per-chunk copying/conversion into DuckDB vectors.

## Test backlog

**P1** Add GC/lifetime tests.

- Drop R registration objects, run
  [`gc()`](https://rdrr.io/r/base/gc.html), then call the DuckDB UDF.
- Close connections after registrations and confirm no crashes.

**P1** Add repeated connect/disconnect tests.

- Acceptance: runtime registry and per-UDF registry do not use stale
  database handles or stale connection-plan state.

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

**P0** Add R 4.3 validation.

- Acceptance: package installs and core tests run under R 4.3.x,
  matching the lowered dependency floor.

## Semantic documentation backlog

Note: `docs/` is ignored in this repository; use `git add -f docs/...`
for docs that should be committed.

**P0** Update `docs/EXECUTION_PLANS.md` with:

- implemented matrix above
- no-fallback principle
- current registration-time vs query-time marshalling behavior
- [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)
  counters and examples

**P2** Update README with a short
[`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)
example after API stabilizes.

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
