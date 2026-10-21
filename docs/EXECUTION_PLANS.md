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
  `mode = "vectorized"` for one R call per DuckDB chunk by default
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
  INTERVAL, ENUM, BIT, GEOMETRY, MAP, UNION, VARIANT, and LIST/ARRAY/STRUCT of
  supported types. VARIANT is available only after the loaded runtime passes
  the canonical logical-type and physical-vector-layout probe.
  Selected scalar-UDF globals may be serialized normally or, with
  `ipc_globals_share = "mori"`, sent as same-host mori shared-memory references
  for large read-only R objects.

## Concurrency choices

- `serial`: DuckDB invokes the callback on the recorded R thread, one callback at
  a time for Rducks purposes. Internal reference plan only.
- `inproc_concurrent`: DuckDB may invoke callbacks from worker threads. Off-main
  callbacks queue synchronous requests to the recorded R thread. R API work and
  user R function evaluation remain serialized on that thread. This backs the
  public `transport = "inproc"` plan. Queue draining preserves each original
  callback by default, including its input chunk and `return_null` error scope.
  A registration may explicitly set `coalesce = TRUE` to merge eligible pending
  chunks into one R call (up to 32 chunks / 65,536 rows), then slice the result
  back to the original requests. This requires a static vectorized direct
  signature with plain BOOLEAN, integer up to 32 bits, FLOAT, DOUBLE, or VARCHAR
  inputs, `side_effects = FALSE`, and `exception_handling = "rethrow"`. The
  caller promises that evaluating concatenated inputs yields the concatenation
  of separately evaluated results with the same NULL handling. Chunk-dependent
  functions such as `cumsum(x)`, `seq_along(x)`, or `x - mean(x)` do not satisfy
  this promise. Request/task identity is retained; queue arrival does not
  establish source row order. `rducks_explain_udf()` reports the registration's
  coalescing option.
  `rducks_query_stream()` provides a managed driver for this plan, subject to
  the dependency and source restrictions below. Ordinary DBI execution still
  blocks the R thread in duckdb-r's `Execute()`: it drains the queue only during
  its own Rducks callbacks and a short idle window afterwards. All-worker
  callback placement, small sources, and query tails can therefore time out.
  A parallel source does not guarantee progress. Explicit single-threaded
  execution avoids that starvation; Rducks does not change plans automatically.
- `multiprocess_parallel`: chunk work is sent to persistent worker processes
  over the NNG provider (`ipc_nng_pool`). Backs the public `transport = "ipc"`
  plan for the supported wire types.

## Managed in-process query streams

With the concurrent `inproc` plan, `rducks_query_stream()` uses one persistent
native helper for preparation, pending execution, fetching and teardown. The
recorded R thread stays in a service loop, evaluates queued scalar callbacks,
and checks interrupts while a native command runs. The handoff holds at most
one fetched DuckDB chunk; R materializes that chunk directly on its own thread.
Native execution may retain additional operator state as required by the query.

Each stream has a reference-counted query owner. Queued requests retain their
original task identity and result destination. The pump selects only that
owner's work, and coalescing also requires the same owner and queue generation.
It does not wait for lower task ordinals or establish source-row callback order.
Pausing between batches is permitted: managed pending requests are governed by
their query owner's cancellation state, rather than the legacy queue deadline.
Ordinary queued requests still use an elapsed monotonic deadline, independent
of condition-variable notification counts.

Cancellation closes admission before interrupting the native connection.
Pending requests finish with an error; a running request retains its callback
state until it reaches `DONE`. The R thread services shutdown until native
resources are destroyed and the helper is joined. Native query errors, end of
input, explicit close, handle garbage collection, and release of the last Rducks
runtime anchor all close the stream. Use `$close()` after early exit, including
an error while processing or assembling a returned R batch. R operations that
do not cooperate with interrupts cannot be forcibly preempted safely.

Only one stream may be open per database runtime. Recursive stream calls and
release from a callback are rejected; plan and scheduler changes are rejected
while a stream is open, including through a sibling DBI connection. Existing
serial and IPC stream paths remain synchronous.

Managed startup requires duckdb-r's versioned off-main R-source guard capability.
The pinned [companion patch and installer](../tools/compat/README.md) provide
version 1 for duckdb-r 1.5.6. Stock builds without it fail before helper startup.
The guard rejects R-backed environment/Arrow replacement scans, Arrow factories,
and R data-frame binding before they enter R from the helper. Rducks R table and
aggregate callbacks are also unsupported in this mode. Native sources and the
queued Rducks scalar-UDF path are supported.

The stream uses an extension-owned database connection. It does not share the
caller's temporary tables/views, uncommitted transaction or connection-local
settings. Last-anchor release for a file-backed database closes the internal
connections; disconnect and reconnect before enabling that database again.
Ordinary DBI integration with the caller's actual connection remains separate
work. The companion guard does not supply that integration.

## Scalar-UDF engines

| Engine ID | Plan (marshalling + concurrency) | Status | Notes |
| --- | --- | --- | --- |
| `direct_serial` | `direct + serial` | internal reference | Reference path; constructed internally for conformance, not exposed publicly. |
| `direct_main_queue` | `direct + inproc_concurrent` | enabled (public `inproc`) | Queued direct marshalling; inputs/results use owned state before crossing threads. R work runs on the recorded R thread. |
| `ipc_nng_pool` | `wire + multiprocess_parallel` | enabled (public `ipc`) | Native NNG request/reply with owned Quack wire bytes and persistent workers. Covers fixed-width scalars, VARCHAR/BLOB, DECIMAL, INTERVAL, ENUM, BIT, GEOMETRY, MAP, UNION, VARIANT, and LIST/ARRAY/STRUCT of supported types; VARIANT is runtime-probed and fail-closed. |

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
