# Persistent IPC Provider

`arrow_ipc + multiprocess_parallel` currently uses one provider: `ipc_nng_pool`.

The provider is not a general task queue. Each DuckDB UDF callback sends one
synchronous native NNG request/reply through a per-UDF client pool, waits under
`ipc_timeout`, imports the Arrow IPC result into the callback-owned DuckDB output
vector, and returns.

## Contract

- Workers are persistent R processes reachable through NNG/nanonext endpoints.
- Rducks can launch local worker loops with mirai daemons, or use explicit
  externally managed NNG endpoint URLs.
- Each UDF is registered once per provider pool. Registration sends the closure,
  declared types, NULL/error policy, output schema description, packages, and
  selected globals to workers.
- Each chunk request carries request type, UDF id, row count, and owned Arrow IPC
  input bytes.
- Each response carries status, plain error text, and owned Arrow IPC result
  bytes.
- DuckDB worker callbacks do not call the R API.

## Non-contracts

- `ipc_max_pending` is an admission bound for simultaneous native requests. It
  is not a queued scheduler size.
- There is no collect-many protocol, task id, chunk id, or out-of-order result
  reassembly in the current provider.
- IPC work must not silently fall back to same-process execution or R
  serialization.
