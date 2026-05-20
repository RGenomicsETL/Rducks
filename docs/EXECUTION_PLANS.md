# Rducks Execution Plans

Execution plans select the marshalling implementation and concurrency contract
used by future DuckDB scalar UDF registrations on a connection. They do not
change the SQL semantics of a scalar UDF.

## DuckDB function kind vs Rducks evaluation mode vs execution plan

Rducks exposes distinct APIs for distinct DuckDB function kinds:

- `rducks_register_scalar_udf()` registers a DuckDB scalar UDF: one SQL result
  value per logical input row.
- `rducks_register_aggregate()` registers a DuckDB aggregate function.
- `rducks_register_table()` registers a DuckDB table function.

These are scalar-UDF registration semantics and belong to
`rducks_register_scalar_udf()`:

- Rducks evaluation mode: `mode = "scalar"` for one R call per row, or
  `mode = "vectorized"` for one R call per DuckDB chunk
- argument and return type descriptors
- `null_handling`
- `exception_handling`
- `side_effects`

These are execution-plan choices for scalar UDFs:

- marshalling: `arrow_r`, `arrow_c`, or `arrow_ipc`
- concurrency: `serial`, `inproc_concurrent`, or `multiprocess_parallel`
- IPC worker options for `arrow_ipc + multiprocess_parallel`

The plan active at registration time selects the evaluator and marshalling
metadata stored with that registered DuckDB scalar UDF. Changing a connection's
default plan later affects future scalar-UDF registrations and updates the native
runtime backend/thread settings, but it does not rewrite an existing UDF from one
marshalling engine to another.

Aggregate functions registered with `rducks_register_aggregate()` are separate
from the scalar-UDF evaluation-mode/execution-plan matrix. Their state contract
is explicit: DuckDB aggregate state stores preserved R object references managed
by Rducks, and `NULL` means empty/no state. Row-wise callbacks use
`update(state, ...)`, `combine(left, right)`, and `finalize(state)`; optional
chunk callbacks operate on lists of state objects. R callbacks are
single-threaded and require the recorded calling R thread.

Table functions registered with `rducks_register_table()` are separate from this
scalar-UDF evaluation-mode/execution-plan matrix. Rducks infers the positional
SQL argument count from the R function formals, registers those input slots as
DuckDB `ANY`, converts the actual SQL bind values to R values, and calls the R
function during bind on the recorded calling R thread. The R function may return
a finite data-frame/list/nanoarrow result or a `rducks_table_stream()` object.
Finite results are imported once during bind through nanoarrow Arrow C Data;
streaming results use only the prototype at bind time and call `next_batch()`
during scan to import successive batches. Worker-thread calls into R are
rejected; use `rducks_enable(con, threads = "single")` for this path.

DuckDB table functions are more general than the current Rducks table API, but
this document describes only the implemented Rducks surface: dynamic output
schema from the bind-time R result/prototype, dynamic positional input values,
and SQL argument count fixed by the R function's formal argument count.

## Strict-plan rule

A registered DuckDB scalar UDF resolves to one evaluator/marshalling engine:

```text
scalar-UDF registration spec + connection default plan
  -> plan validation
  -> native scalar-UDF evaluator/marshalling metadata
  -> no fallback to another marshalling engine
```

For concurrency demonstrations and benchmarks, set the matching plan again before
execution so the native runtime backend and DuckDB thread settings match the UDF
metadata being exercised.

Unsupported combinations must fail. They must not silently switch:

- from `arrow_c` to `arrow_r`
- from `arrow_ipc` to R serialization or same-process execution
- from vectorized chunk calls to scalar row calls
- from direct native conversion to an Arrow helper path

## Marshalling choices

- `arrow_r`: reference path through DuckDB Arrow C Data and nanoarrow/R
  materialization.
- `arrow_c`: direct DuckDB-vector materialization for signatures accepted by the
  direct support predicate. Unsupported signatures fail validation.
- `arrow_ipc`: owned Arrow IPC request/result bytes. This is only valid with
  `multiprocess_parallel`. The current NNG provider is one request to exactly
  one result record batch; multi-batch or streaming results are rejected rather
  than concatenated implicitly. Selected scalar-UDF globals may be serialized
  normally or, with `ipc_globals_share = "mori"`, sent as same-host mori
  shared-memory references for large read-only R objects.

## Concurrency choices

- `serial`: DuckDB invokes the callback on the recorded R thread, one callback at
  a time for Rducks purposes.
- `inproc_concurrent`: DuckDB may invoke callbacks from worker threads. Off-main
  callbacks queue synchronous requests to the recorded R thread. R API work and
  user R function evaluation remain serialized on that thread.
- `multiprocess_parallel`: chunk work is sent to persistent worker processes over
  the selected IPC provider. The current provider is `ipc_nng_pool`.

## Implemented scalar-UDF engines

| Engine ID | Public plan | Scalar evaluation mode | Vectorized evaluation mode | Notes |
| --- | --- | --- | --- | --- |
| `arrow_r_serial` | `arrow_r + serial` | yes | yes | Reference path. |
| `arrow_r_main_queue` | `arrow_r + inproc_concurrent` | yes | yes | Same-process queue; R work runs on the recorded R thread. |
| `arrow_c_direct_serial` | `arrow_c + serial` | yes | yes | Direct native marshalling for supported signatures. |
| `arrow_c_direct_main_queue` | `arrow_c + inproc_concurrent` | yes | yes | Queued direct marshalling; inputs/results use owned state before crossing threads. |
| `ipc_nng_pool` | `arrow_ipc + multiprocess_parallel` | yes | yes | Native NNG request/reply with owned Arrow IPC bytes and persistent workers. |

## Arrow IPC enum storage

Declared `ENUM(...)` levels are part of the Rducks registration type descriptor.
For `arrow_ipc`, Rducks transports enum columns as their underlying DuckDB enum
index storage, with Arrow dictionaries removed at the IPC boundary. The worker
reconstructs `rducks_enum` values from the declared levels and storage indexes.

## Current validation coverage

The test suite exercises the reference `arrow_r + serial` path, supported
`arrow_c` direct paths, same-process queue paths, and the NNG-backed
`arrow_ipc + multiprocess_parallel` path. Coverage includes scalar and
vectorized calls, default and special NULL handling, `exception_handling =
"return_null"` on non-reference plans, unsupported signature validation, native
counter checks for selected engines, IPC codec validation, provider startup
retry behavior, and generated/dynamic marshalling matrices for declared and
bind-time argument types.

The generated marshalling matrix remains the broadest conformance check. Narrow
unit tests cover helper contracts such as execution-plan shortcut resolution,
mode/value semantic tables, query-stream type reconstruction, and IPC worker
introspection.
