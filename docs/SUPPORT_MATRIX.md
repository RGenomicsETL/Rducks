# Rducks Support Matrix And Ownership Notes

This document summarizes the supported execution-plan surface. The code-level
truth is the plan/type validation predicates and the generated marshalling matrix.
For thread-boundary details, treat `docs/ARCHITECTURE.md` as the narrative source
and this document as the compact support table.

## Scalar-UDF execution engines

These engines apply to DuckDB scalar UDFs registered with
`rducks_register_scalar_udf()`. `Scalar` and `Vectorized` below are Rducks
evaluation modes for the scalar UDF, not separate DuckDB function kinds.

| Public plan | Engine ID | Scalar evaluation mode | Vectorized evaluation mode | Notes |
| --- | --- | --- | --- | --- |
| internal `direct + serial` | `direct_serial` | supported | supported | Reference path; constructed internally, not exposed publicly. |
| `inproc` (`direct + inproc_concurrent`) | `direct_main_queue` | supported | supported | Direct DuckDB-vector marshalling with owned queued input/result state; R work stays on the recorded R thread. |
| `ipc` (`wire + multiprocess_parallel`) | `ipc_nng_pool` | supported | supported | Persistent worker processes, native NNG request/reply, owned Quack wire bytes. Covers the wire-supported scalar types (see below); other signatures are rejected at registration. |

Invalid marshalling/concurrency pairs fail validation.

## Aggregate functions

`rducks_register_aggregate()` is a separate DuckDB aggregate-function surface,
not an execution-plan variant of DuckDB scalar UDFs. The supported state
representation is an R object reference preserved by Rducks and stored through
native DuckDB aggregate state; `NULL` means empty/no state. Row-wise
`update()`/`combine()` callbacks and optional chunk callbacks may return any R
object state or `NULL`; `finalize()` returns the declared scalar result.
Registration and R callbacks require the recorded calling R thread
(`external_threads=1` and `PRAGMA threads=1`); parallel worker-thread R callbacks
are rejected.

## Streaming queries

`rducks_query_stream()` opens a native DuckDB streaming result and returns rows
in DuckDB-sized batches as data frames. Each batch is materialized directly from
DuckDB vectors to R values on the recorded R thread. The stream uses the
extension's database-scoped connection, so it cannot see caller-connection
temporary tables or views, uncommitted transactions, or connection-local
settings.

| Stream path | Execution and R callbacks | Requirements and limits |
| --- | --- | --- |
| Concurrent `inproc` | Persistent native helper prepares, executes, fetches and tears down; the recorded R thread services queued scalar callbacks and interrupts. | Requires duckdb-r off-main R-source guard capability v1 or newer. Native sources and queued Rducks scalar UDFs are supported. R-backed source binding, R table functions and R aggregates are rejected. |
| Serial / `ipc` | Existing synchronous native stream path. | No managed-helper capability requirement; the selected plan's existing restrictions apply. |
| Ordinary DBI query | duckdb-r's synchronous query path. | Concurrent in-process callbacks still depend on callback-driven queue service and can starve when the R thread is blocked in native execution. |

Only one stream can be open per database runtime. Managed fetching transfers at
most one chunk at a time; this is a result-handoff bound, not a bound on DuckDB
operator memory. The stream closes on EOF, native error, explicit close, handle
garbage collection, or release of the last runtime anchor. Explicitly close it
after early exit or errors in R-side batch processing. Cancellation is scoped to
the stream's query owner; requests retain their original task identity and
destination. Recursive stream/release calls and live-stream plan changes fail.

The [pinned guard companion](../tools/compat/README.md) is tested with duckdb-r
1.5.6 on Linux amd64; it is not an accepted upstream API. The installer and real
SIGINT harness currently target Linux/POSIX. macOS/Windows managed execution
and the optional Arrow integration test have not been verified in this change.
Stock duckdb-r builds reject managed startup explicitly. See
[`EXECUTION_PLANS.md`](EXECUTION_PLANS.md) for lifecycle and connection details.

## Type-family support

The `direct` column covers the in-process `inproc` plan. The `wire` column
covers the `ipc` worker-process Quack codec. `wire` is enabled, but the worker
bridge currently covers fixed-width scalars, `VARCHAR`/`BLOB`, `DECIMAL`,
`INTERVAL`, `ENUM`, `BIT`, `GEOMETRY`, `MAP`, `UNION`, `VARIANT`, and
`LIST`/`ARRAY`/`STRUCT` of supported types. `VARIANT` is available only when the
loaded runtime passes the native logical-type and vector-layout probe.

| Type family | Examples | `direct` | `wire` (`ipc`) | Notes |
| --- | --- | --- | --- | --- |
| Boolean/numeric scalars | `BOOLEAN`, integer widths, `FLOAT`, `DOUBLE` | yes | yes | Values are materialized/copied as R values or vectors. Validity bitmaps remain authoritative for NULLs. |
| String/binary | `VARCHAR`, `BLOB` | yes | yes | Returned binary data is copied into DuckDB-owned output storage. |
| Bit | `BIT` | yes | yes | `rducks_bits` (packed bits + length); transported as DuckDB's physical bit storage (padding-header byte + MSB-first bits). |
| Geometry | `GEOMETRY` | yes | yes | `GEOMETRY` crosses the R boundary as its opaque physical `raw` bytes (WKB for a real geometry); it is physically a varlen blob and rides the wire as a BLOB column, reconstructed from its declared type. The bytes are transported verbatim, not parsed. |
| Semi-structured | `VARIANT` | runtime-gated | runtime-gated | Rducks obtains a canonical logical type from DuckDB's SQL binder and enables the type only after a dynamic probe verifies the complete `STRUCT(keys, children, values, data)` vector layout. Direct and Quack paths expose that typed storage as `rducks_variant`; the wire path transports the same physical struct. R and native external-worker boundaries validate type ids, indexes, byte offsets, nested ranges, forward-only tree references, and payload bounds before writeback. Construct/extract semantic JSON-like values in SQL with DuckDB VARIANT functions. Incompatible or changed runtime layouts are rejected at registration. |
| Temporal | `DATE`, `TIME`, `TIMESTAMP` | yes | yes | R-side shapes are defined by Rducks conversion helpers/value classes. |
| Interval | `INTERVAL` | yes | yes | `rducks_interval` value class; transported as the 16-byte months/days/micros storage. |
| Wide integers/UUID | `HUGEINT`, `UHUGEINT`, `UUID` | yes | yes | Uses Rducks value classes where base R has no exact scalar. |
| Decimal | `DECIMAL(width, scale)` | yes | yes | Use the `DECIMAL()` constructor, not a quoted SQL type string. Transported as the scaled-integer storage across all four physical widths (2/4/8/16 bytes). |
| Enum | `ENUM(c("a", "b"))` | yes | yes | Declared levels plus the underlying 0-based dictionary index storage; the worker reconstructs `rducks_enum` from the levels. |
| Lists/arrays | `INTEGER[]`, `DOUBLE[3]` | yes where the child is supported | yes where the child is supported | Child descriptors are validated recursively; the wire bridge marshals offsets/lengths and the child vector. |
| Struct | `STRUCT(...)` | yes where children are supported | yes where children are supported | The wire bridge marshals each member vector recursively; arbitrary nesting (struct of list, list of struct, etc.) is covered. |
| Map | `MAP(...)` | yes where children are supported | yes where children are supported | Transported as `LIST(STRUCT(key, value))`, matching DuckDB's physical layout; key/value child types are validated recursively. |
| Union | `UNION(...)` | yes where children are supported | yes where members are supported | Transported as DuckDB's physical `STRUCT(tag, members...)`, so the active member tag is explicit (an active-but-NULL member is distinct from an inactive one). Member types are validated recursively. |

## NULL and error semantics

| Option | Supported values | Contract |
| --- | --- | --- |
| `null_handling` | `"default"`, `"special"` | Default skips rows with SQL NULL inputs when possible. Special passes the declared R-side missing shape. |
| `exception_handling` | `"rethrow"`, `"return_null"` | User R errors become DuckDB errors or SQL NULLs according to policy. Type/marshalling bugs should still fail loudly. |
| queued running request lifetime | preserved through `DONE` | Cancellation may stop admission and interrupt a managed query, but cannot free a running callback's input/result state before evaluation and cleanup finish. |

## Scope and lifetime

| Scope | Owns | Release behavior |
| --- | --- | --- |
| R process/package | recorded R-thread identity, provider factories, release queues, diagnostics | Process-global. Safe drain points release preserved objects on the R thread. |
| DuckDB database runtime/catalog | SQL UDFs, evaluator handles, preserved closures, counters, frozen evaluator/marshalling metadata, runtime backend, query-stream owners | Database-scoped and visible to sibling DBI connections. Last-attachment release closes streams and joins managed helpers. For file-backed databases it also closes internal connections; reconnect before re-enabling. Catalog functions are not unregistered. |
| DBI connection attachment | default plan for future registrations, finalizer bookkeeping, R-side registry view | `rducks_release(con)` clears this scope only. |

## Copy/borrow expectations

- Rducks does not expose a zero-copy return contract.
- Borrowed DuckDB vectors/data chunks are callback-local.
- Same-process queued `direct` requests copy inputs into owned native state
  before crossing to the recorded R thread.
- Queued results are written into owned result state before a waiting worker
  writes callback output.
- Quack wire request/result payloads (`ipc` path) are owned raw bytes and
  must not hide R `serialize()` payloads or process-local pointers.
- Same-host `ipc_globals_share = "mori"` is only a long-lived global-sharing
  path. Built-in IPC backends currently report `supports_chunk_shared_memory_handles = FALSE`;
  no SQL chunk data-plane shared-memory handles are supported yet.
