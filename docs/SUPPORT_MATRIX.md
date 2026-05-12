# Rducks Support Matrix And Ownership Notes

This document summarizes the supported execution-plan surface. The code-level
truth is the plan/type validation predicates and the generated marshalling matrix.

## Execution engines

| Public plan | Engine ID | Scalar | Vectorized | Notes |
| --- | --- | --- | --- | --- |
| `arrow_r + serial` | `arrow_r_serial` | supported | supported | Reference path through Arrow C Data and nanoarrow/R. |
| `arrow_r + inproc_concurrent` | `arrow_r_main_queue` | supported | supported | Queued same-process callbacks; R work stays on the recorded R thread. |
| `arrow_c + serial` | `arrow_c_direct_serial` | supported | supported | Direct DuckDB-vector marshalling for supported signatures. |
| `arrow_c + inproc_concurrent` | `arrow_c_direct_main_queue` | supported | supported | Same direct marshalling with owned queued input/result state. |
| `arrow_ipc + multiprocess_parallel` | `ipc_nng_pool` | supported | supported | Persistent worker processes, native NNG request/reply, owned Arrow IPC bytes. |

Invalid marshalling/concurrency pairs fail validation.

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
| DuckDB database runtime/catalog | SQL UDFs, evaluator handles, preserved closures, counters, frozen engine metadata | Database-scoped and visible to sibling DBI connections. |
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
