# Rducks Architecture

Rducks is an R package plus a DuckDB C extension. The package validates R API
calls, loads the extension, and records connection-local defaults. The extension
owns DuckDB catalog registration, database-runtime state, and native callback
execution.

## Layers

### R package layer

- validates `rducks_enable()`, `rducks_register_scalar_udf()`, aggregate/table registration, and execution-plan options
- builds normalized type descriptors and registration specs
- records connection-local default plans and R-side diagnostics
- prepares R wrapper functions used by the native evaluators
- starts/stops local IPC worker providers when an `arrow_ipc` plan needs them

### DuckDB extension layer

- registers SQL functions and extension diagnostic surfaces
- stores per-database runtime records and per-UDF native metadata
- preserves R evaluator objects while DuckDB catalog metadata can call them
- exports/imports DuckDB chunks through DuckDB C APIs
- runs direct `arrow_c` vector materialization where the support predicate allows
- owns the in-process queue used when DuckDB callbacks arrive off the recorded R
  thread
- owns native NNG client pools used by `arrow_ipc + multiprocess_parallel`

### Marshalling layer

- `arrow_r`: DuckDB chunk -> Arrow C Data -> nanoarrow/R values -> Arrow C Data
  result -> DuckDB output
- `arrow_c`: direct DuckDB-vector reads/writes for supported scalar and
  vectorized signatures
- `arrow_ipc`: DuckDB chunk -> owned Arrow IPC request bytes -> worker process ->
  owned Arrow IPC result bytes -> DuckDB output

## DuckDB function kind, evaluation mode, and execution plan

DuckDB function kind is the SQL catalog shape: scalar UDF, aggregate function,
or table function. `rducks_register_scalar_udf()` registers DuckDB scalar UDFs,
`rducks_register_aggregate()` registers DuckDB aggregate functions, and
`rducks_register_table()` registers DuckDB table functions.

For DuckDB scalar UDFs only, `mode = "scalar"` calls the R function once per
logical row and `mode = "vectorized"` calls the R function once per DuckDB chunk
with R vectors or list-columns. This Rducks evaluation mode is user semantics
and is independent of the execution plan.

An execution plan chooses marshalling and concurrency (`arrow_r`, `arrow_c`, or
`arrow_ipc`; `serial`, `inproc_concurrent`, or `multiprocess_parallel`) for
future scalar-UDF registrations and updates the native runtime backend used for
matching concurrent execution. It must not redefine DuckDB SQL type, NULL, or
result semantics.

## Thread boundary

DuckDB worker threads must not call the R API. In-process R execution is legal
only on the recorded R thread. If DuckDB invokes a scalar UDF from another thread,
`inproc_concurrent` submits a synchronous request to the extension-owned queue;
the recorded R thread drains that request and performs all R work.

The queue is a liveness/safety mechanism, not parallel R execution. R callbacks
remain serialized on the recorded R thread. Worker-side code may copy DuckDB
vectors into owned native state, wait, and write DuckDB output after the R-thread
phase has produced owned result data.

## Ownership rules

- Borrowed DuckDB vectors and data chunks are valid only during the scalar-UDF,
  aggregate, table-function, or query callback that supplied them.
- Borrowed `SEXP` objects and nanoarrow R external pointers must not cross to a
  DuckDB worker thread.
- Queued off-main requests must carry owned native input/result state or remain
  synchronous until borrowed callback-local state is no longer needed.
- Arrow IPC payloads are owned byte buffers. They are used only for explicit
  process/transport boundaries.
- Same-host mori sharing is only for long-lived R globals today; SQL chunk
  shared-memory handles are not implemented and must remain distinct from the
  current owned-byte data plane.
- Native destructors that cannot safely call the R API must queue release work or
  leak conservatively rather than call `R_ReleaseObject()` from an unsafe thread.

## Runtime scopes

- **R process/package**: recorded R-thread token, provider factories, release
  queues, and package diagnostics.
- **DuckDB database runtime/catalog**: SQL functions, evaluator handles,
  preserved closures, frozen evaluator/marshalling metadata, runtime backend,
  and counters.
- **DBI connection attachment**: default execution plan for future registrations,
  finalizer bookkeeping, and the R-side registry view.

`rducks_release(con)` clears connection-local Rducks state. It is not an
unregister operation and must not drop database-catalog functions that sibling
connections can still call. For `arrow_ipc + multiprocess_parallel`, releasing
the last Rducks attachment to a runtime also closes native client pools for
Rducks-launched local workers and stops those local mirai/NNG workers. If
`ipc_endpoints` was supplied, those URLs name user-owned worker processes;
Rducks does not send stop requests to them during release.
