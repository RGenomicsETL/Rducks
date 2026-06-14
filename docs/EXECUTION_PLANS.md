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

- marshalling: `direct` (in-process) or `wire` (worker-process Quack codec)
- concurrency: `serial` or `inproc_concurrent` for `direct`; `wire` pairs with `multiprocess_parallel`
- IPC worker options for the `wire + multiprocess_parallel` transport

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
function during bind on the recorded calling R thread.

`rducks_register_table()` fills DuckDB output vectors directly from the R
function's returned columns (data frame, named list, or `rducks_table_stream()`
producer); column types are inferred from the returned columns. Finite results
are imported once during bind; stream results import batches as DuckDB scans.

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

- from `direct` to the `wire` path or vice versa
- from vectorized chunk calls to scalar row calls
- from direct native conversion to any other helper path

## Marshalling choices

- `direct`: direct DuckDB-vector materialization to/from R values for signatures
  accepted by the direct support predicate. Unsupported signatures fail validation.
- `wire`: owned Quack wire request/result bytes (DuckDB BinarySerializer subset),
  marshalled to worker R processes. Only valid with `multiprocess_parallel`. The
  worker path currently covers fixed-width scalars, VARCHAR/BLOB, DECIMAL,
  INTERVAL, ENUM, BIT, GEOMETRY, MAP, UNION, and LIST/ARRAY/STRUCT of supported types; VARIANT is rejected at
  registration until the native bridge covers it.
  Selected scalar-UDF globals may be serialized normally or, with
  `ipc_globals_share = "mori"`, sent as same-host mori shared-memory references
  for large read-only R objects.

## Concurrency choices

- `serial`: DuckDB invokes the callback on the recorded R thread, one callback at
  a time for Rducks purposes. Internal reference plan only.
- `inproc_concurrent`: DuckDB may invoke callbacks from worker threads. Off-main
  callbacks queue synchronous requests to the recorded R thread. R API work and
  user R function evaluation remain serialized on that thread. This backs the
  public `transport = "inproc"` plan.
- `multiprocess_parallel`: chunk work is sent to persistent worker processes
  over the NNG provider (`ipc_nng_pool`). Backs the public `transport = "ipc"`
  plan for the supported wire types.

## Scalar-UDF engines

| Engine ID | Plan (marshalling + concurrency) | Status | Notes |
| --- | --- | --- | --- |
| `direct_serial` | `direct + serial` | internal reference | Reference path; constructed internally for conformance, not exposed publicly. |
| `direct_main_queue` | `direct + inproc_concurrent` | enabled (public `inproc`) | Queued direct marshalling; inputs/results use owned state before crossing threads. R work runs on the recorded R thread. |
| `ipc_nng_pool` | `wire + multiprocess_parallel` | enabled (public `ipc`) | Native NNG request/reply with owned Quack wire bytes and persistent workers. Covers fixed-width scalars, VARCHAR/BLOB, DECIMAL, INTERVAL, ENUM, BIT, GEOMETRY, MAP, UNION, and LIST/ARRAY/STRUCT of supported types; VARIANT is rejected at registration. |

## Enum storage (wire path)

Declared `ENUM(...)` levels are part of the Rducks registration type descriptor.
On the `wire` path, Rducks transports enum columns as their underlying DuckDB
0-based dictionary-index storage (1/2/4 bytes by dictionary size); the dictionary
travels with the wire type and the worker reconstructs `rducks_enum` values from
the declared levels and storage indexes.

## Current validation coverage

The test suite exercises the `direct` paths (internal `direct + serial`
reference and the public `direct + inproc_concurrent` queue). Coverage includes
scalar and vectorized calls, default and special NULL handling,
`exception_handling = "return_null"`, unsupported signature validation, native
counter checks for selected engines, and the standalone Quack wire codec
round-trip tests that back the worker-process path.
