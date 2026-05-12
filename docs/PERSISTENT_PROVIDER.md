# Persistent IPC Provider

`arrow_ipc + multiprocess_parallel` currently uses one provider: `ipc_nng_pool`.

The provider is not a general task queue. Each DuckDB UDF callback sends one
synchronous native NNG request/reply through a per-UDF client pool, waits under
`ipc_timeout`, imports the Arrow IPC result into the callback-owned DuckDB output
vector, and returns.

## Contract

- Workers are persistent R processes reachable through NNG/nanonext endpoints.
- Rducks can launch local worker loops with mirai daemons. TCP and WebSocket
  local startup retries with fresh endpoint bundles after startup-ping failure,
  because randomly selected loopback ports can race with other processes. The
  default retry budget is three attempts with a short fixed pause; option
  `rducks.nng.startup_attempts` can adjust the attempt count. If explicit
  `ipc_endpoints` are supplied, Rducks connects to worker URLs that the caller
  starts and stops and does not retry with replacement endpoints.
- Each UDF is registered once per provider pool. Registration sends the closure,
  declared types, NULL/error policy, output schema description, packages, and
  selected globals to workers. With `ipc_globals = "auto"`, Rducks estimates the
  serialized globals payload before broadcast and can warn or fail via options
  `rducks.ipc_globals.warn_bytes` and `rducks.ipc_globals.max_bytes`.
- Each chunk request carries request type, UDF id, row count, and owned Arrow IPC
  input bytes.
- Each response carries status, plain error text, and owned Arrow IPC result
  bytes. A successful result payload must contain exactly one Arrow IPC record
  batch with the requested row count; empty payloads, missing batches, and
  trailing batches are hard errors.
- DuckDB worker callbacks do not call the R API.

## Non-contracts

- `ipc_max_pending` is an admission bound for simultaneous native requests. It
  is not a queued scheduler size.
- There is no collect-many protocol, task id, chunk id, streaming result, or
  out-of-order result reassembly in the current provider.
- IPC work must not silently fall back to same-process execution or R
  serialization.
