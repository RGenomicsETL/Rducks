# Rducks Support Matrix And Ownership Notes

This document summarizes the supported execution-plan surface. The code-level
truth is the plan/type validation predicates and the generated marshalling matrix.

## Scalar-UDF execution engines

These engines apply to DuckDB scalar UDFs registered with
`rducks_register_scalar_udf()`. `Scalar` and `Vectorized` below are Rducks
evaluation modes for the scalar UDF, not separate DuckDB function kinds.

| Public plan | Engine ID | Scalar evaluation mode | Vectorized evaluation mode | Notes |
| --- | --- | --- | --- | --- |
| `arrow_r + serial` | `arrow_r_serial` | supported | supported | Reference path through Arrow C Data and nanoarrow/R. |
| `arrow_r + inproc_concurrent` | `arrow_r_main_queue` | supported | supported | Queued same-process callbacks; R work stays on the recorded R thread. |
| `arrow_c + serial` | `arrow_c_direct_serial` | supported | supported | Direct DuckDB-vector marshalling for supported signatures. |
| `arrow_c + inproc_concurrent` | `arrow_c_direct_main_queue` | supported | supported | Same direct marshalling with owned queued input/result state. |
| `arrow_ipc + multiprocess_parallel` | `ipc_nng_pool` | supported | supported | Persistent worker processes, native NNG request/reply, owned Arrow IPC bytes. |

Invalid marshalling/concurrency pairs fail validation.

## Aggregate functions

`rducks_register_aggregate()` is a separate DuckDB aggregate-function surface,
not an execution-plan variant of DuckDB scalar UDFs. The only supported
state representation is native DuckDB aggregate memory containing a copied R
`raw` vector. `update()` and optional `combine()` must return raw state or
`NULL`; `finalize()` returns the declared scalar result. Registration and R
callbacks require the recorded calling R thread (`external_threads=1` and
`PRAGMA threads=1`); parallel worker-thread R callbacks are rejected.

## Streaming queries

`rducks_query_stream()` is a connection-bound R-side result/session API. It
opens a native DuckDB streaming result through the Rducks extension, fetches
DuckDB data chunks with `duckdb_stream_fetch_chunk()`, exports them through
DuckDB Arrow C Data, and materializes data-frame batches with Rducks' existing
nanoarrow conversion helpers. The stream query scope is the database-scoped
extension connection, not caller-connection temporary tables/views. It closes the
native streaming result on `close()`, finalization, or `rducks_release(con)`, and
does not survive connection release.

## Type-family support

| Type family | Examples | `arrow_r` | `arrow_c` | `arrow_ipc` | Notes |
| --- | --- | --- | --- | --- | --- |
| Boolean/numeric scalars | `BOOLEAN`, integer widths, `FLOAT`, `DOUBLE` | yes | yes | yes | Values are materialized/copied as R values or vectors. |
| String/binary/bit | `VARCHAR`, `BLOB`, `BIT` | yes | yes | yes | Returned data is copied into DuckDB-owned output storage. |
| Temporal | `DATE`, `TIME`, `TIMESTAMP`, `INTERVAL` | yes | yes | yes | R-side shapes are defined by Rducks conversion helpers/value classes. |
| Wide integers/UUID | `HUGEINT`, `UHUGEINT`, `UUID` | yes | yes | yes | Uses Rducks value classes where base R has no exact scalar. |
| Decimal | `DECIMAL(width, scale)` | yes | yes | yes | Use the `DECIMAL()` constructor, not a quoted SQL type string. |
| Enum | `ENUM(c("a", "b"))` | yes | yes | yes | IPC uses declared levels plus underlying enum index storage, not dictionary transport. |
| Lists/arrays | `INTEGER[]`, `DOUBLE[3]` | yes | yes where direct predicate accepts child | yes | Child descriptors are validated recursively. |
| Struct/map/union | `STRUCT(...)`, `MAP(...)`, `UNION(...)` | yes | yes where direct predicate accepts children | yes | Direct support depends on native DuckDB-vector handling for the child types. |

## NULL and error semantics

| Option | Supported values | Contract |
| --- | --- | --- |
| `null_handling` | `"default"`, `"special"` | Default skips rows with SQL NULL inputs when possible. Special passes the declared R-side missing shape. |
| `exception_handling` | `"rethrow"`, `"return_null"` | User R errors become DuckDB errors or SQL NULLs according to policy. Type/marshalling bugs should still fail loudly. |
| queued running cancellation | not supported | Once a same-process queued request is running, callback-owned state must remain live until writeback completes. |

## Scope and lifetime

| Scope | Owns | Release behavior |
| --- | --- | --- |
| R process/package | recorded R-thread identity, provider factories, release queues, diagnostics | Process-global. Safe drain points release preserved objects on the R thread. |
| DuckDB database runtime/catalog | SQL UDFs, evaluator handles, preserved closures, counters, frozen evaluator/marshalling metadata, runtime backend | Database-scoped and visible to sibling DBI connections. |
| DBI connection attachment | default plan for future registrations, finalizer bookkeeping, R-side registry view | `rducks_release(con)` clears this scope only. |

## Copy/borrow expectations

- Rducks does not expose a zero-copy return contract.
- Borrowed DuckDB vectors/data chunks are callback-local.
- Same-process queued `arrow_c` requests copy inputs into owned native state
  before crossing to the recorded R thread.
- Queued results are written into owned result state before a waiting worker
  writes callback output.
- Arrow IPC request/result payloads are owned raw bytes and must not hide R
  `serialize()` payloads or process-local pointers.
- Same-host `ipc_globals_share = "mori"` is only a long-lived global-sharing
  path. Built-in IPC backends currently report `supports_chunk_shared_memory_handles = FALSE`;
  no SQL chunk data-plane shared-memory handles are supported yet.
