# Rducks Execution Plans And Validation Checklist

This document is the design target for keeping Rducks execution principled as it
moves from the current same-process implementation toward native chunk paths and
true multiprocess parallelism.

The core rule is:

> Registration states the UDF semantics. A connection/session execution plan
> states how chunks are evaluated. The runtime resolves exactly one plan and
> never silently falls back to another plan.

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
- `arrow_c`: C/native DuckDB-vector and Arrow-compatible materialization. This
  includes the current RC scalar row-loop and a future first-class native
  vectorized chunk evaluator.
- `arrow_ipc`: owned Arrow IPC bytes as the process/thread transport boundary.

### Concurrency model

Use Bengtsson's principle: say what should happen concurrently, not the private
mechanism used to make it happen.

- `serial`: Rducks evaluates one chunk at a time in the calling process. This is
  the boring reference/liveness baseline.
- `inproc_concurrent`: DuckDB may issue in-process UDF chunk work concurrently.
  R API work and R function evaluation are still serialized on the recorded R
  execution lane. The goal is same-process liveness and no deadlocks, not
  parallel R speed.
- `multiprocess_parallel`: multiple chunks may be evaluated concurrently in
  isolated R worker processes. Worker lifecycle may be implemented with
  mirai-style machinery, but the plan name does not expose that mechanism.

Avoid public plan names such as `main_lane`, `queue`, `pump`, `mirai`, or
`sockets`; those describe mechanisms, not concurrency semantics.

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

A UDF invocation resolves to exactly one execution plan:

```text
registered UDF semantics + active connection/session plan
  -> exact plan validation
  -> exact plan execution
```

If the plan cannot support the declared signature or semantic options, Rducks
must fail loudly before execution when possible, and at execution only as a
safety net. It must not silently switch:

- from `arrow_c` to `arrow_r`;
- from `arrow_ipc` to R serialization;
- from `multiprocess_parallel` to same-process execution;
- from vectorized chunk calls to scalar row calls;
- from a native direct path to an Arrow helper path unless that helper is an
  explicit part of the same named plan.

An implementation may be internally factored into helper functions, but the
observable plan remains one named plan with one declared support matrix.

## Target plan matrix

| Marshalling | Concurrency | Scalar status | Vectorized status | Notes |
| --- | --- | --- | --- | --- |
| `arrow_r` | `serial` | implemented/reference | implemented/reference | The semantic oracle for all other plans. |
| `arrow_r` | `inproc_concurrent` | implemented | implemented | Same-process liveness path; R still runs serialized on the recorded R lane. |
| `arrow_c` | `serial` | implemented as current RC scalar | planned | Native materialization and native row/chunk control; no fallback to `arrow_r`. |
| `arrow_c` | `inproc_concurrent` | implemented for current RC scalar | planned | Same semantics as `arrow_c + serial`, but requests may enter from concurrent DuckDB callbacks and must run R API work on the recorded R lane. |
| `arrow_ipc` | `multiprocess_parallel` | planned | planned | Owned Arrow IPC request/result bytes across process boundary. Scalar still batches transport by chunk and loops rows inside the worker. |

Current API compatibility:

- `eval_mode = "R"` maps to `arrow_r` today.
- `eval_mode = "RC"` maps to `arrow_c` today for scalar mode.
- `rducks_enable_inproc()` maps the connection to `inproc_concurrent` today.

Target API direction:

- keep `rducks_register()` focused on UDF semantics;
- move marshalling/concurrency selection to a connection/session execution-plan
  API;
- keep current API as compatibility shims until the new plan API is ready.

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
- R API and R function calls happen only on the recorded R execution lane;
- timeout paths fail with a clear error and increment timeout counters;
- no borrowed DuckDB vectors or transient `SEXP`s cross threads;
- queued work uses owned request/result state or runs synchronously while
  borrowed pointers remain callback-local.

Additional multiprocess cases:

- request payload is Arrow IPC bytes, not R `serialize()` output;
- result payload is Arrow IPC bytes;
- worker errors propagate with function name, chunk/request id, and original R
  condition text where possible;
- worker crash/timeout/cancellation returns a deterministic query error;
- no process-local R object pointer is sent across process boundaries;
- chunk order and result row order are preserved or explicitly reassembled.

## Implementation checklist

### Iteration 0: freeze principles

- [ ] Add this execution-plan vocabulary to public/internal architecture docs.
- [ ] State that `arrow_r + serial` is the reference, not a fallback.
- [ ] State the no-fallback rule in registration and runtime docs.
- [ ] Decide public names for concurrency: `serial`, `inproc_concurrent`,
      `multiprocess_parallel` unless a better what-not-how name is chosen.
- [ ] Decide whether `mode` remains the public spelling of `call_shape`.

### Iteration 1: make plan resolution explicit internally

- [ ] Add an internal execution-plan object or struct with fields:
      `marshaller`, `concurrency`, `call_shape`, `null_handling`,
      `exception_handling`, and plan id.
- [ ] Store the resolved plan id in native UDF metadata.
- [ ] Add a plan validator that checks the full UDF signature before native
      registration succeeds.
- [ ] Add plan introspection for tests, e.g. `rducks_explain_udf()` or a SQL
      debug surface returning the resolved plan id.
- [ ] Add counters per plan id so tests can prove no fallback path executed.

### Iteration 2: harden the reference

- [ ] Treat `arrow_r + serial + scalar` as the scalar reference in generated
      tests.
- [ ] Treat `arrow_r + serial + vectorized` as the vectorized reference in
      generated tests.
- [ ] Expand the generated matrix until it covers every claimed public type and
      every NULL/error semantic option.
- [ ] Add negative generated cases for unsupported plan/type combinations.
- [ ] Run the generated matrix in CI, not only manually.

### Iteration 3: reframe current RC as `arrow_c + scalar`

- [ ] Rename internal comments/docs from generic `RC` to `arrow_c scalar` where
      possible while preserving public compatibility.
- [ ] Ensure current direct-buffer and Arrow-helper RC paths are one named plan,
      not an implicit fallback from one plan to another.
- [ ] Document exactly which helpers are part of that plan.
- [ ] Add tests proving `arrow_c + scalar` matches `arrow_r + serial + scalar`
      for all supported signatures.
- [ ] Add tests proving unsupported scalar signatures fail plan validation rather
      than switching to `arrow_r`.

### Iteration 4: design `arrow_c + vectorized`

- [ ] Define the complete v1 supported type matrix.
- [ ] Reject every unsupported signature at registration/plan-validation time.
- [ ] Implement native chunk argument materialization for the v1 matrix.
- [ ] Implement native default/special NULL row selection.
- [ ] Call the R function exactly once per evaluated chunk.
- [ ] Validate vectorized return length in C/R-thread-safe code.
- [ ] Scatter returned values and SQL NULLs to DuckDB output vectors.
- [ ] Add conformance tests against `arrow_r + serial + vectorized`.
- [ ] Add tests proving no scalar row-loop is used for vectorized calls.

### Iteration 5: make concurrency a connection/session execution plan

- [ ] Introduce a connection/session-level execution-plan API.
- [ ] Keep `rducks_enable()` and `rducks_enable_inproc()` as compatibility
      shims that set execution plans.
- [ ] Remove evaluator/concurrency selection from the conceptual UDF semantic
      contract.
- [ ] Validate all registered UDFs when the connection/session plan changes.
- [ ] Validate a UDF against the active plan when registering after a plan has
      been set.
- [ ] Preserve no-fallback behavior at query execution.

### Iteration 6: implement `arrow_ipc + multiprocess_parallel`

- [ ] Define request envelope: UDF id, plan id, chunk id, schema, input IPC,
      semantic options, timeout/cancellation metadata.
- [ ] Define response envelope: chunk id, result IPC or structured error.
- [ ] Encode DuckDB input chunks to owned Arrow IPC bytes in the DuckDB process.
- [ ] Decode input IPC in worker R processes.
- [ ] Execute scalar/vectorized call shape inside each worker.
- [ ] Encode result IPC in worker R processes.
- [ ] Import result IPC into DuckDB output vectors.
- [ ] Add worker lifecycle/shutdown/cancellation tests.
- [ ] Add tests proving hot-path payloads are Arrow IPC and not R
      `serialize()`/`unserialize()`.

### Iteration 7: release gates

- [ ] Every public plan has a documented support matrix.
- [ ] Every unsupported combination has a deterministic error message.
- [ ] Every non-reference plan has generated conformance against the reference.
- [ ] CI runs tinytests, generated matrix, and at least one concurrency stress
      job.
- [ ] User docs distinguish semantic call shape from execution plan.
- [ ] Changelog describes user-facing capabilities without internal-agent notes.
