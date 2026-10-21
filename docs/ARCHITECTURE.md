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
- starts/stops local NNG worker providers for the worker-process `ipc` transport

### DuckDB extension layer

- registers SQL functions and extension diagnostic surfaces
- stores per-database runtime records and per-UDF native metadata
- preserves R evaluator objects while DuckDB catalog metadata can call them
- reads/writes DuckDB chunks through DuckDB C APIs
- runs direct DuckDB-vector materialization where the support predicate allows
- owns the in-process queue used when DuckDB callbacks arrive off the recorded R
  thread
- owns native NNG client pools for the worker-process `ipc` transport

### Marshalling layer

- `direct`: direct DuckDB-vector reads/writes to/from R values for supported
  scalar and vectorized signatures, on the recorded R thread, with no
  intermediate columnar format
- `wire` (`ipc`): DuckDB chunk -> owned Quack wire bytes (DuckDB
  BinarySerializer subset) -> worker process -> owned Quack result bytes ->
  DuckDB output. Enabled for fixed-width scalars, VARCHAR/BLOB, DECIMAL,
  INTERVAL, ENUM, BIT, GEOMETRY, MAP, UNION, VARIANT, and LIST/ARRAY/STRUCT of
  supported types. VARIANT is fail-closed unless the loaded runtime passes the
  canonical logical-type and physical-vector-layout probe.

## DuckDB function kind, evaluation mode, and execution plan

DuckDB function kind is the SQL catalog shape: scalar UDF, aggregate function,
or table function. `rducks_register_scalar_udf()` registers DuckDB scalar UDFs,
`rducks_register_aggregate()` registers DuckDB aggregate functions, and
`rducks_register_table()` registers DuckDB table functions.

For DuckDB scalar UDFs only, `mode = "scalar"` calls the R function once per
logical row and `mode = "vectorized"` calls the R function once per DuckDB chunk
with R vectors or list-columns. This Rducks evaluation mode is user semantics
and is independent of the execution plan.

An execution plan chooses marshalling and concurrency (`direct` with
`inproc_concurrent`, or `wire` with `multiprocess_parallel` for the
worker-process `ipc` transport) for future scalar-UDF registrations and updates
the native runtime backend used for matching concurrent execution. It must not
redefine DuckDB SQL type, NULL, or result semantics.

## Thread boundary

DuckDB worker threads must not call the R API. In-process R execution is legal
only on the recorded R thread. If DuckDB invokes a scalar UDF from another thread,
`inproc_concurrent` submits a synchronous request to the extension-owned queue;
the recorded R thread drains that request and performs all R work.

The queue is a liveness/safety mechanism, not parallel R execution. R callbacks
remain serialized on the recorded R thread. Worker-side code may copy DuckDB
vectors into owned native state, wait, and write DuckDB output after the R-thread
phase has produced owned result data.

### Managed query driver

For concurrent in-process query streams, a persistent native helper owns all
DuckDB preparation, execution, fetch and teardown operations. The public R
stream calls a versioned C-callable bridge directly, outside duckdb-r's SQL
interrupt handler. A constant-token bind handshake registers that bridge on
the recorded R thread; scalar execution of the handshake remains native-only.
The package never casts a duckdb-r external pointer or borrows its connection.

The R side pumps callbacks while each helper command is active. A bounded
handoff transfers one fetched native chunk back for direct R materialization.
A reference-counted query owner outlives any individual stream handle and is
captured only by callbacks on the driver's actual native connection. Queue
selection and cancellation use that owner; legacy DBI drains cannot consume
managed requests. Coalesced callbacks retain each request's output destination
and require the same owner and generation.

Close first stops new submissions and interrupts the owned connection. Pending
requests are rejected, running callbacks reach `DONE`, native resources are
destroyed, and the helper joins before stream state is freed. R unwind cleanup
destroys partial owned outputs and restores active callback/batch state. Runtime
tokens include a generation, so a stale handle cannot operate on a newly opened
runtime. Runtime entries remain inert after release for destructor safety.

Off-thread preparation can encounter database-wide R-backed replacement scans,
even on the extension's own connection. Managed startup therefore requires a
versioned duckdb-r guard that rejects the audited R source/binding callbacks
before they touch R on another thread. The narrow companion is documented in
[`tools/compat/README.md`](../tools/compat/README.md). R table and aggregate
callbacks fail in managed mode; scalar callbacks use the queue. Serial and IPC
streams retain their synchronous paths. Ordinary DBI execution still has the
callback-driven queue progress limitation described in
[`EXECUTION_PLANS.md`](EXECUTION_PLANS.md).

## Ownership rules

- Borrowed DuckDB vectors and data chunks are valid only during the scalar-UDF,
  aggregate, table-function, or query callback that supplied them.
- Borrowed `SEXP` objects must not cross to a DuckDB worker thread.
- Queued off-main requests must carry owned native input/result state or remain
  synchronous until borrowed callback-local state is no longer needed.
- Quack wire payloads are owned byte buffers. They are used only for explicit
  process/transport boundaries.
- Same-host mori sharing is only for long-lived R globals today; SQL chunk
  shared-memory handles are not implemented and must remain distinct from the
  current owned-byte data plane.
- Native destructors that cannot safely call the R API must queue release work or
  leak conservatively rather than call `R_ReleaseObject()` from an unsafe thread.

## Runtime scopes

`docs/SUPPORT_MATRIX.md` contains the compact scope/lifetime table; this section
is the narrative source for how those scopes interact.

- **R process/package**: recorded R-thread token, provider factories, release
  queues, and package diagnostics.
- **DuckDB database runtime/catalog**: SQL functions, evaluator handles,
  preserved closures, frozen evaluator/marshalling metadata, runtime backend,
  and counters.
- **DBI connection attachment**: default execution plan for future registrations,
  finalizer bookkeeping, and the R-side registry view.

`rducks_release(con)` clears connection-local Rducks state. It is not an
unregister operation and must not drop database-catalog functions that sibling
connections can still call. For the worker-process `ipc` transport,
releasing the last Rducks attachment to a runtime also closes native client
pools for Rducks-launched local workers and stops those local mirai/NNG
workers. If
`ipc_endpoints` was supplied, those URLs name user-owned worker processes;
Rducks does not send stop requests to them during release. For file-backed
DuckDB databases, releasing the last attachment also closes Rducks'
extension-owned DuckDB connections while keeping the process-local runtime entry
inert for catalog-destructor safety and stale address detection.

The last runtime attachment also closes all query streams and joins managed
helpers, including for in-memory databases that retain their catalog connection.
A callback cannot recursively release its runtime, and an open stream prevents
plan/scheduler reconfiguration through any attached or sibling connection.
Call `rducks_release(con)` before disconnecting the DBI connection. After final
file-backed release, use a new DBI connection before enabling that database again.
