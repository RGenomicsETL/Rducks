# Rducks Support Matrix And Ownership Notes

This document is the checklist companion to `docs/EXECUTION_PLANS.md`. It keeps
public claims about supported plans, type families, and lifetime semantics in one
place.

## Execution engines

| Engine ID | Public plan | Scalar UDFs | Vectorized UDFs | Notes |
| --- | --- | --- | --- | --- |
| `arrow_r_serial` | `arrow_r + serial` | supported/reference | supported/reference | Uses Arrow C Data plus nanoarrow/R materialization. |
| `arrow_r_main_queue` | `arrow_r + inproc_concurrent` | supported | supported | DuckDB worker callbacks queue work; R evaluation runs on the recorded main R thread. |
| `arrow_c_direct_serial` | `arrow_c + serial` | supported | supported | Direct native DuckDB-vector marshalling only; unsupported signatures fail. |
| `arrow_c_direct_main_queue` | `arrow_c + inproc_concurrent` | supported | supported | Same direct marshalling as serial, with queued main-thread R evaluation. |
| `ipc_future_pool` | `arrow_ipc + multiprocess_parallel` | implemented/experimental | implemented/experimental | Native Arrow IPC request/result bytes with generic `future` workers; portable correctness path. |
| `ipc_mirai_pool` | `arrow_ipc + multiprocess_parallel` with `ipc_provider = "mirai"` | implemented/experimental | implemented/experimental | Persistent mirai workers preload evaluator/schema state and use the same owned Arrow IPC payload contract. |

Invalid combinations are intentionally rejected rather than mapped to another
engine.

## Type-family support

| Type family | Examples | `arrow_r` | `arrow_c` direct | `arrow_ipc` | Notes |
| --- | --- | --- | --- | --- | --- |
| Boolean/numeric scalars | `BOOL`, signed/unsigned integers, `FLOAT`, `DOUBLE` | yes | yes | experimental yes | Scalar inputs are materialized as R values/vectors; no hidden pointer aliasing is promised. |
| String/binary | `VARCHAR`, `BLOB`, `BIT` | yes | yes | experimental yes | Returned strings/buffers are copied into the destination representation. |
| Temporal | `DATE`, `TIME`, `TIMESTAMP`, `INTERVAL` | yes | yes | experimental yes | Rducks conversion helpers define the R-side value classes. |
| Wide integers/UUID | `HUGEINT`, `UHUGEINT`, `UUID` | yes | yes | experimental yes | Represented with Rducks value classes where base R has no exact scalar type. |
| Decimal | `DECIMAL(width, scale)` | yes | yes | experimental yes | Must use `DECIMAL()` type constructors, not quoted SQL strings. |
| Enum | `ENUM(c("a", "b"))` | yes | yes | experimental yes | Arrow IPC carries enum storage indices plus the Rducks type descriptor; this is not general Arrow dictionary IPC support. |
| Lists/arrays | `LIST(I32)`, `ARRAY(F64, 3)` | yes | yes | experimental yes | Nested child descriptors are validated before registration. |
| Struct/map/union | `STRUCT(...)`, `MAP(...)`, `UNION(...)` | yes | yes | experimental yes | Direct UNION support depends on the pinned DuckDB C-vector layout and is covered by generated matrix tests. |

The generated marshalling matrix is the operational truth for claimed type
coverage; the latest full run passed 1213 cases across scalar/vectorized modes,
`arrow_r`, direct `arrow_c`, and supported `arrow_ipc` mappings. Unsupported
signatures must fail at registration/plan validation time where possible.

## NULL and error semantics

| Option | Supported values | Contract |
| --- | --- | --- |
| `null_handling` | `"default"`, `"special"` | Default skips rows with NULL arguments where possible; special passes the declared R-side NULL/NA shapes to the UDF. |
| `exception_handling` | `"rethrow"`, `"return_null"` | R errors are caught inside callback fences and converted to DuckDB errors or NULL results according to policy. |
| Running queued timeout | not supported | Once a queued same-process request is running, the stack request and callback-owned output vector prevent safe cancellation. Queued direct `arrow_c` inputs are now snapshotted, but diagnostics still report `running_timeout_supported = FALSE`. |

## Scope and lifetime

| Scope | Owns | Release behavior |
| --- | --- | --- |
| R process/package | recorded main R thread, preserved-object release queue, provider factories, package diagnostics | Process-global; safe drain points release queued preserved objects on the main R thread. |
| DuckDB database/catalog runtime | registered SQL functions, evaluator handles, preserved closures while catalog metadata refers to them, per-UDF counters and frozen engine metadata | Database-scoped; sibling DBI connections to the same database share catalog functions. |
| DBI connection attachment | current/default plan for future registrations, attachment/finalizer bookkeeping, R-side registry view | `rducks_release(con)`/detach clears only this scope and must not drop catalog functions. |

Preserved R closures are not owned by the DBI connection that registered them.
They live while database-catalog UDF metadata refers to the evaluator handle.
Native destructors that cannot safely call the R API enqueue preserved objects for
release on the recorded main R thread.

`rducks_explain_udf()` includes `r_side_record` to distinguish an ordinary
current-session R registry record from native UDF metadata that remains after the
R-side registry view has been detached.

## Copy/borrow expectations

- Rducks does not expose a zero-copy return contract. Returned scalars, strings,
  nested values, and Arrow-imported result chunks are copied/materialized into
  DuckDB-owned callback output storage.
- Same-process queued direct `arrow_c` scalar/vectorized requests copy input
  vectors into an owned DuckDB data chunk on the worker before the request is
  submitted to the recorded main R thread. For queued direct `arrow_c` UDFs with
  supported scalar returns (bool, integer widths, floating point,
  date/time/timestamp, VARCHAR/BLOB/BIT, DECIMAL, ENUM, UUID, HUGEINT/UHUGEINT,
  and INTERVAL), return values are copied into an owned Arrow C Data result chunk
  on the recorded main R thread and the waiting worker writes the DuckDB output
  vector from those Arrow buffers without touching `SEXP`s or nanoarrow R
  external pointers. Other same-process return paths still write output on the
  recorded main R thread. Running cancellation remains unsupported because the
  stack request and callback-owned output vector must stay live until the main
  thread and any worker-side writeback finish.
- Arrow IPC payloads are owned raw-byte payloads intended to cross process
  boundaries. The implementation must not use R `serialize()` or raw external
  `SEXP` pointers as a hidden transport fallback.
- `arrow_c` means direct native conversion. Any Arrow/R bridge or helper path
  must be a separately named plan if reintroduced.
