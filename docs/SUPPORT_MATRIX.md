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
| `inproc` (`direct + inproc_concurrent`) | `direct_main_queue` | supported | supported | Direct DuckDB-vector marshalling with owned queued input/result state; R work stays on the recorded R thread. The only public plan. |
| reserved `wire + multiprocess_parallel` | `ipc_nng_pool` | (reserved) | (reserved) | Persistent worker processes, native NNG request/reply, owned Quack wire bytes. Not yet enabled. |

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

The `rducks_query_stream()` surface was removed with the Arrow data plane and is
pending reimplementation over the Quack wire codec. There is no streaming-query
API in this build.

## Type-family support

The `direct` column is the only enabled marshalling. The `wire` column is the
reserved worker-process codec and is not yet enabled.

| Type family | Examples | `direct` | `wire` (reserved) | Notes |
| --- | --- | --- | --- | --- |
| Boolean/numeric scalars | `BOOLEAN`, integer widths, `FLOAT`, `DOUBLE` | yes | yes | Values are materialized/copied as R values or vectors. Validity bitmaps remain authoritative for NULLs. |
| String/binary/geometry/bit | `VARCHAR`, `BLOB`, `GEOMETRY`, `BIT` | yes | yes | Returned binary data is copied into DuckDB-owned output storage. `GEOMETRY` crosses the R boundary as WKB `raw` bytes. |
| Semi-structured | `VARIANT` | yes where DuckDB's C API exposes `VARIANT` logical types | yes where DuckDB's C API exposes `VARIANT` logical types | Rducks exposes DuckDB's typed VARIANT storage struct as `rducks_variant`; construct/extract semantic JSON-like values in SQL with DuckDB VARIANT functions. Early DuckDB 1.5 builds (including 1.5.2) can parse VARIANT SQL but cannot register C API scalar UDFs with VARIANT signatures. |
| Temporal | `DATE`, `TIME`, `TIMESTAMP`, `INTERVAL` | yes | yes | R-side shapes are defined by Rducks conversion helpers/value classes. |
| Wide integers/UUID | `HUGEINT`, `UHUGEINT`, `UUID` | yes | yes | Uses Rducks value classes where base R has no exact scalar. |
| Decimal | `DECIMAL(width, scale)` | yes | yes | Use the `DECIMAL()` constructor, not a quoted SQL type string. |
| Enum | `ENUM(c("a", "b"))` | yes | yes | The reserved wire path uses declared levels plus underlying enum index storage. |
| Lists/arrays | `INTEGER[]`, `DOUBLE[3]` | yes where direct predicate accepts child | yes | Child descriptors are validated recursively. |
| Struct/map/union | `STRUCT(...)`, `MAP(...)`, `UNION(...)` | yes where direct predicate accepts children | yes | Direct support depends on native DuckDB-vector handling for the child types. The direct UNION adapter follows DuckDB's current native UNION tag/child vector layout and is version-coupled. |

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
| DuckDB database runtime/catalog | SQL UDFs, evaluator handles, preserved closures, counters, frozen evaluator/marshalling metadata, runtime backend | Database-scoped and visible to sibling DBI connections. For file-backed databases, last-attachment release closes Rducks' extension-owned DuckDB connections but does not unregister catalog functions. |
| DBI connection attachment | default plan for future registrations, finalizer bookkeeping, R-side registry view | `rducks_release(con)` clears this scope only. |

## Copy/borrow expectations

- Rducks does not expose a zero-copy return contract.
- Borrowed DuckDB vectors/data chunks are callback-local.
- Same-process queued `direct` requests copy inputs into owned native state
  before crossing to the recorded R thread.
- Queued results are written into owned result state before a waiting worker
  writes callback output.
- Quack wire request/result payloads (reserved path) are owned raw bytes and
  must not hide R `serialize()` payloads or process-local pointers.
- Same-host `ipc_globals_share = "mori"` is only a long-lived global-sharing
  path. Built-in IPC backends currently report `supports_chunk_shared_memory_handles = FALSE`;
  no SQL chunk data-plane shared-memory handles are supported yet.
