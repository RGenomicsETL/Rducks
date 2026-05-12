# Rducks Execution Plans

Execution plans select the marshalling implementation and concurrency contract
used by future UDF registrations on a connection. They do not change the user
semantics of a UDF.

## UDF semantics vs execution plan

These are UDF semantics and belong to `rducks_register()`:

- `mode = "scalar"` or `mode = "vectorized"`
- argument and return type descriptors
- `null_handling`
- `exception_handling`
- `side_effects`

These are execution-plan choices:

- marshalling: `arrow_r`, `arrow_c`, or `arrow_ipc`
- concurrency: `serial`, `inproc_concurrent`, or `multiprocess_parallel`
- IPC worker options for `arrow_ipc + multiprocess_parallel`

The plan active at registration time is frozen into that registered DuckDB
catalog UDF. Changing a connection's default plan later affects only future
registrations.

## Strict-plan rule

A registered UDF resolves to one engine:

```text
registration spec + connection default plan
  -> plan validation
  -> frozen native UDF metadata
  -> that engine for every invocation
```

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
  `multiprocess_parallel`.

## Concurrency choices

- `serial`: DuckDB invokes the callback on the recorded R thread, one callback at
  a time for Rducks purposes.
- `inproc_concurrent`: DuckDB may invoke callbacks from worker threads. Off-main
  callbacks queue synchronous requests to the recorded R thread. R API work and
  user R function evaluation remain serialized on that thread.
- `multiprocess_parallel`: chunk work is sent to persistent worker processes over
  the selected IPC provider. The current provider is `ipc_nng_pool`.

## Implemented engines

| Engine ID | Public plan | Scalar | Vectorized | Notes |
| --- | --- | --- | --- | --- |
| `arrow_r_serial` | `arrow_r + serial` | yes | yes | Reference path. |
| `arrow_r_main_queue` | `arrow_r + inproc_concurrent` | yes | yes | Same-process queue; R work runs on the recorded R thread. |
| `arrow_c_direct_serial` | `arrow_c + serial` | yes | yes | Direct native marshalling for supported signatures. |
| `arrow_c_direct_main_queue` | `arrow_c + inproc_concurrent` | yes | yes | Queued direct marshalling; inputs/results use owned state before crossing threads. |
| `ipc_nng_pool` | `arrow_ipc + multiprocess_parallel` | yes | yes | Native NNG request/reply with owned Arrow IPC bytes and persistent workers. |

## Arrow IPC limits

The current native Arrow IPC path rejects declared `ENUM(...)` descriptors,
including nested enum children. Rducks owns the NNG frame, but the chunk payload
is still an Arrow IPC stream written with vendored nanoarrow C/IPC; DuckDB exports
enums as dictionary arrays and that writer does not accept the dictionary layout
used here. Do not document enum support for `arrow_ipc` until native input/output
rewriting converts declared enums to a supported storage representation.

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
