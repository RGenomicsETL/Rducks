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
is explicit: DuckDB aggregate state stores copied raw bytes, not R object
pointers; R `update()`/`combine()` callbacks must return raw state or `NULL`;
`finalize()` returns the declared scalar result. R callbacks are single-threaded
and require the recorded calling R thread.

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

DuckDB table functions are more general than the current Rducks table API. Their
bind phase can inspect constant input arguments, decide the output schema
dynamically, and
DuckDB's function catalog can contain overloads with distinct input signatures.
Rducks should not model table functions as inherently declared-schema or
zero-argument; this API supports dynamic output schemas and dynamic positional
input types, while SQL argument count is currently fixed by the R function's
formal argument count.

DuckDB's R package is the important registration-time no-materialization
precedent for static R data frames. `duckdb_register()` creates a DuckDB view
over `r_dataframe_scan(POINTER(df), ...)`; the `r_dataframe_scan` bind callback
inspects the R `data.frame`, builds DuckDB column names/types from the R
columns, stores protected references plus raw column data pointers in bind data,
and fills projected DuckDB chunks from those R vectors. Environment scans use
replacement-scan rewriting to produce the same table-function call. That route
avoids Rducks' per-value result marshalling and should remain the recommended
path when the table already exists as an R data frame at registration time.

Future Rducks table-function work should build on this nanoarrow/DuckDB-chunk
path rather than reintroducing per-value result marshalling. Remaining design
work includes named/optional parameters, broader Arrow ArrayStream handling,
overload-aware registration where each SQL input signature is explicit, and
backend choices that do not redefine SQL type/null/result semantics.

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

## Validation expectations

For any non-reference plan, tests should compare against the matching
`arrow_r + serial` behavior for supported signatures. Useful checks include:

- result equality with `IS NOT DISTINCT FROM` or an equivalent R comparison
- result DuckDB type identity via `typeof()` where relevant
- default and special NULL handling
- `exception_handling = "rethrow"` and `"return_null"`
- vectorized return-length errors
- unsupported signatures failing at registration/plan validation
- native counters proving the selected engine ran and sibling engines did not
- concurrency/timeout tests for queued and IPC plans

The generated marshalling matrix is the main broad-coverage tool, but docs should
state what the code and tests actually cover, not a wish list of completed work.
