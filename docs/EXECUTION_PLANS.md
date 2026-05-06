# Rducks Execution Plans And Validation Checklist

This document is the design target for keeping Rducks execution principled as it
moves from the current same-process implementation toward native chunk paths and
true multiprocess parallelism.

The core rule is:

> Registration states the UDF semantics and freezes the execution engine for
> that catalog UDF. A connection execution plan is only the default for future
> registrations through that connection. The runtime resolves exactly one engine
> per registered UDF and never silently falls back to another engine.

## Vocabulary

### UDF semantics

These belong to `rducks_register()` because they change what the user R function
means:

- `call_shape = "scalar"`: call the R function once per logical DuckDB row.
- `call_shape = "vectorized"`: call the R function once per DuckDB chunk with
  one R vector/list-column per declared argument.
- argument and return types.
- `null_handling`: `default` or `special`.
- `exception_handling`: `rethrow` or `return_null`.
- `side_effects` / purity metadata.

Current API note: `mode` is the current public name for `call_shape`. Keep that
user-facing spelling unless and until there is a deliberate API migration.

### Marshalling implementation

These are execution-plan choices, not UDF semantics:

- `arrow_r`: Arrow C Data plus nanoarrow/R materialization. This is the semantic
  reference implementation.
- `arrow_c`: C/native DuckDB-vector materialization for supported scalar and
  vectorized registrations. This is direct-only: unsupported signatures fail
  validation rather than bridging through Arrow/R helpers. The `RCV` path
  materializes chunk arguments and writes chunk results through direct
  DuckDB-vector helpers.
- `arrow_ipc`: owned Arrow IPC bytes as the process/thread transport boundary.

### Concurrency model

Use Bengtsson's principle: say what should happen concurrently, not the private
mechanism used to make it happen.

- `serial`: Rducks evaluates one chunk at a time in the calling process. This is
  the boring reference/liveness baseline.
- `inproc_concurrent`: DuckDB may issue in-process UDF chunk work concurrently.
  R API work and R function evaluation are still serialized on the recorded main
  R thread. The goal is same-process liveness and no deadlocks, not
  parallel R speed.
- `multiprocess_parallel`: multiple chunks may be evaluated concurrently in
  isolated R worker processes. Worker lifecycle may be implemented with
  mirai-style machinery, but the plan name does not expose that mechanism.

Avoid public plan names such as `main_thread_loop`, `queue`, `pump`, `mirai`,
or `sockets`; those describe mechanisms, not concurrency semantics.

## Reference implementation contract

`arrow_r + serial` is the hard reference implementation for semantics.

Reference means:

- it is complete for the public type surface that Rducks claims to support;
- it is boring and explicit, not tuned for clever performance;
- it does not call another evaluator as a fallback;
- every other execution plan is tested against it for every supported
  signature and semantic option;
- it may be slower than other plans, but it must be easier to reason about.

There are two reference call shapes:

- `arrow_r + serial + scalar`: scalar reference.
- `arrow_r + serial + vectorized`: vectorized reference.

Scalar and vectorized modes are not universally equivalent because side effects,
R call counts, and vectorized user code can differ. Scalar-vs-vectorized
conformance tests should therefore use specially constructed functions such as
identity or simple pure transformations where the expected equivalence is part of
the test case.

## No-fallback rule

A UDF invocation resolves to exactly one frozen execution engine:

```text
rducks_register() semantics + connection default plan at registration time
  -> exact plan validation
  -> frozen UDF engine metadata
  -> exact engine execution for every invocation
```

Changing a sibling connection's default execution plan later must not mutate the
engine for already-registered database-catalog UDFs.

If the plan cannot support the declared signature or semantic options, Rducks
must fail loudly before execution when possible, and at execution only as a
safety net. It must not silently switch:

- from `arrow_c` to `arrow_r`;
- from `arrow_ipc` to R serialization;
- from `multiprocess_parallel` to same-process execution;
- from vectorized chunk calls to scalar row calls;
- from a native direct path to an Arrow helper path.

An implementation may be internally factored into helper functions, but the
observable plan remains one named plan with one declared support matrix.

## Target plan matrix

| Engine ID | Marshalling | Concurrency | Scalar status | Vectorized status | Notes |
| --- | --- | --- | --- | --- | --- |
| `arrow_r_serial` | `arrow_r` | `serial` | implemented/reference | implemented/reference | The semantic oracle for all other engines. |
| `arrow_r_main_queue` | `arrow_r` | `inproc_concurrent` | implemented | implemented | Same-process liveness path; R still runs serialized on the recorded main R thread. |
| `arrow_c_direct_serial` | `arrow_c` | `serial` | implemented | implemented | Direct native scalar/vectorized evaluators (`RC`/`RCV`); no Arrow/R bridge fallback. |
| `arrow_c_direct_main_queue` | `arrow_c` | `inproc_concurrent` | implemented | implemented | Same direct marshalling semantics as `arrow_c + serial`, but requests may enter from concurrent DuckDB callbacks and must run R API work on the recorded main R thread. |
| `ipc_future_pool` | `arrow_ipc` | `multiprocess_parallel` | implemented | implemented | Generic Future-backed Arrow IPC request/result payloads. Scalar mode loops over rows inside the worker; vectorized mode calls once per chunk. The native extension implements the UDF path in C by submitting Arrow IPC chunk work, cooperatively draining queued worker callbacks when execution reaches the main R thread, collecting Future results, and copying returned Arrow results into the DuckDB output vector. |

Current API direction:

- `rducks_register()` is focused on UDF semantics and freezes the resolved
  execution plan/engine into the database-scoped UDF metadata;
- marshalling/concurrency selection lives in a connection execution-plan API, but
  the connection's current plan is only the default for future registrations;
- `rducks_current_execution_plan()` reports that R-side default plan;
- `rducks_native_execution_backend()` reports the native database-scoped backend
  currently installed for the runtime as a diagnostic cross-check;
- `rducks_enable_inproc()` is a compatibility helper that sets the connection's
  concurrency to `inproc_concurrent` while preserving the current marshalling
  choice.


## Database catalog and connection scope

DuckDB function catalog entries are database-scoped. Sibling DBI connections to
the same in-process database can see the same registered SQL functions. Rducks
therefore separates three scopes:

- **R process/package scope**: recorded main R thread identity, release queue,
  package diagnostics, and provider factories.
- **DuckDB database runtime/catalog scope**: registered Rducks SQL functions,
  opaque evaluator handles, frozen UDF engine metadata, counters, and preserved
  R closures while catalog metadata refers to them.
- **DBI connection attachment scope**: the connection-local default execution
  plan and finalizer bookkeeping.

`rducks_release(con)`/detach is non-destructive: it clears connection-local
defaults and R registry views, but it must not drop database-catalog functions or
release closures still owned by catalog UDF metadata. `rducks_explain_udf()`
reports `r_side_record = FALSE` when native UDF metadata remains available but
the detached R-side registry record is not present.

## Validation requirements for every non-reference plan

For each supported plan, generated validation must compare the plan under test
against the matching `arrow_r + serial` reference.

Required generated cases:

- all supported argument and return type signatures;
- ordinary non-null values;
- SQL NULL inputs;
- `null_handling = "default"`;
- `null_handling = "special"`;
- R `NULL` returns where SQL NULL is expected;
- type-specific NA returns where supported;
- `exception_handling = "rethrow"`;
- `exception_handling = "return_null"`;
- result SQL type identity via `typeof()` or equivalent DuckDB inspection;
- `IS NOT DISTINCT FROM` result equality;
- unsupported signatures fail at registration/plan-validation time.

Additional vectorized cases:

- R function is called fewer times than rows for multi-row chunks;
- returned vector/list length must equal evaluated-row count;
- all top-level-NULL chunks with `null_handling = "default"` do not call R;
- default NULL handling scatters SQL NULLs into skipped rows;
- special NULL handling passes full chunk with scalar-mode NA/NULL shapes;
- scalar-vs-vectorized conformance only for explicitly pure/equivalent test
  functions.

Additional concurrency cases:

- `inproc_concurrent` has no deadlock under concurrent DuckDB callback pressure;
- R API and R function calls happen only on the recorded main R thread;
- timeout paths fail with a clear error and increment timeout counters;
- no borrowed DuckDB vectors or transient `SEXP`s cross threads;
- queued work uses owned request/result state or runs synchronously while
  borrowed pointers remain callback-local.

Additional multiprocess cases:

- request payload is Arrow IPC bytes, not R `serialize()` output;
- result payload is Arrow IPC bytes;
- declared `ENUM(...)` payloads use Rducks' explicit enum-storage convention:
  the Arrow IPC stream carries the DuckDB enum storage indices as ordinary
  integer arrays, while the declared type descriptor carries the dictionary
  levels. This is not general Arrow dictionary IPC support and must not be used
  for arbitrary dictionary arrays;
- worker errors propagate with function name, chunk/request id, and original R
  condition text where possible;
- worker crash/timeout/cancellation returns a deterministic query error;
- no process-local R object pointer is sent across process boundaries;
- chunk order and result row order are preserved or explicitly reassembled.

## Implementation checklist

### Iteration 0: freeze principles

- [x] Add this execution-plan vocabulary to public/internal architecture docs.
- [x] State that `arrow_r + serial` is the reference, not a fallback.
- [x] State the no-fallback rule in registration and runtime docs.
- [x] Decide public names for concurrency: `serial`, `inproc_concurrent`,
      `multiprocess_parallel` unless a better what-not-how name is chosen.
- [x] Decide whether `mode` remains the public spelling of `call_shape`.

### Iteration 1: make plan resolution explicit internally

- [x] Add an internal execution-plan object or struct with fields:
      `marshaller`, `concurrency`, `call_shape`, `null_handling`,
      `exception_handling`, and plan id.
- [x] Store the resolved plan/evaluator identity with the database-scoped UDF
      registration record and expose it through `rducks_explain_udf()`.
- [x] Add a plan validator that checks the full UDF signature before native
      registration succeeds.
- [x] Add R-side plan introspection for tests via
      `rducks_current_execution_plan()` and per-UDF introspection via
      `rducks_explain_udf()` / `rducks_list_udfs()`.
- [x] Add per-marshalling/per-evaluator counters so tests can prove no fallback
      path executed.

### Iteration 2: harden the reference

- [x] Treat `arrow_r + serial + scalar` as the scalar reference in generated
      tests.
- [x] Treat `arrow_r + serial + vectorized` as the vectorized reference in
      generated tests.
- [ ] Expand the generated matrix until it covers every claimed public type and
      every NULL/error semantic option.
- [ ] Add negative generated cases for unsupported plan/type combinations.
- [x] Run the generated matrix in CI, not only manually.

### Iteration 3: reframe current native scalar path as `arrow_c + scalar`

- [ ] Rename internal comments/docs from generic `RC` to `arrow_c scalar` where
      possible.
- [x] Ensure current direct-buffer and Arrow-helper native paths are one named
      plan, not an implicit fallback from one plan to another. `arrow_c` is now
      direct-only; the old helper bridge is not a hidden fallback.
- [x] Document exactly which helpers are part of that plan through
      `docs/SUPPORT_MATRIX.md` and native direct-support predicates.
- [x] Add tests proving `arrow_c + scalar` matches `arrow_r + serial + scalar`
      for all supported signatures.
- [x] Add tests proving unsupported scalar signatures fail plan validation rather
      than switching to `arrow_r`.

### Iteration 4: implement `arrow_c + vectorized`

- [x] Define the complete v1 supported type matrix through the existing direct
      `arrow_c` predicate.
- [x] Implement native chunk argument materialization for the v1 matrix.
- [x] Implement native default/special NULL row selection.
- [x] Call the R function exactly once per evaluated chunk.
- [x] Validate vectorized return length in R helper code while native code
      catches the error before returning to DuckDB.
- [x] Scatter returned values and SQL NULLs to DuckDB output vectors through the
      direct native writer.
- [x] Add broader conformance tests against `arrow_r + serial + vectorized` for
      every direct-supported signature through
      `tools/run_generated_marshalling_matrix.R`.
- [x] Add tests proving `RCV` registration and dispatch use the direct evaluator.

Current implementation note: `arrow_c + vectorized` is available for direct-
supported signatures. The `RCV` evaluator token is accepted by native
registration and dispatches to direct DuckDB-vector materialization/writeback,
not the old Arrow/R helper bridge.

### Iteration 5: make concurrency a registration-time execution plan default

- [x] Introduce a connection-level execution-plan API whose active value is the
      default for future registrations.
- [x] Keep `rducks_enable()` and `rducks_enable_inproc()` as compatibility
      shims that set execution plans.
- [x] Remove evaluator/concurrency selection from the conceptual UDF semantic
      contract.
- [x] Freeze evaluator/marshalling metadata at registration time. Later plan
      changes do not retarget already-registered UDFs, so there is no
      registered-UDF revalidation step on plan changes.
- [x] Validate a UDF against the active plan when registering after a plan has
      been set.
- [x] Preserve no-fallback behavior at query execution.

### Iteration 6: implement `arrow_ipc + multiprocess_parallel`

- [~] Define request envelope: current Future tasks include schema, input IPC,
      semantic options, and timeout; a production RPC envelope still needs UDF
      id, task id, cancellation metadata, and worker lifecycle metadata.
- [~] Define response envelope: current Future workers return Arrow IPC result
      bytes or an R error propagated through Future; a production RPC envelope
      should carry task id plus structured error metadata.
- [x] Encode DuckDB input chunks to Arrow IPC bytes in the DuckDB process for
      the current synchronous UDF callback implementation.
- [x] Decode input IPC in worker R processes.
- [x] Execute scalar/vectorized call shape inside each worker.
- [x] Encode result IPC in worker R processes.
- [x] Import result IPC into DuckDB output vectors.
- [x] Add scalar/vectorized RIPC runtime tests and no-fallback counters.
- [ ] Add worker lifecycle/shutdown/cancellation tests.
- [ ] Add tests proving hot-path payloads are Arrow IPC and not R
      `serialize()`/`unserialize()`.
- [ ] Implement a first-class owned source/query pipeline if we decide to add a
      non-UDF surface: split an input source into owned Arrow IPC tasks, submit a
      window ahead, collect by task sequence, and expose results without
      borrowed scalar-UDF callback pointers. This is separate from the already
      implemented native C scalar-UDF RIPC path.

### Iteration 7: release gates

- [x] Every public plan has a documented support matrix.
- [x] Every unsupported combination has a deterministic error message.
- [~] Every non-reference plan has generated conformance against the reference;
      broad scalar/vectorized coverage exists, but expanded negative and
      semantic-option cases remain useful.
- [x] CI runs tinytests, generated matrix, and at least one concurrency stress
      job.
- [x] User docs distinguish semantic call shape from execution plan.
- [x] Changelog describes user-facing capabilities without internal-agent notes.
