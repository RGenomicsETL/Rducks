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
  `ipc_globals_share = "mori"` applies `mori::share()` to each selected global
  before registration serialization, which can turn large same-host read-only R
  objects into compact shared-memory references. Rducks keeps those shared
  objects anchored in the preserved UDF evaluator metadata.
- Each chunk request carries request type, UDF id, row count, and owned Arrow IPC
  input bytes.
- Each response carries status, plain error text, and owned Arrow IPC result
  bytes. A successful result payload must contain exactly one Arrow IPC record
  batch with the requested row count; empty payloads, missing batches, and
  trailing batches are hard errors.
- DuckDB worker callbacks do not call the R API.

## Globals discovery and shared memory

Automatic global discovery is useful, but it is not a semantic promise that every
R expression's data dependencies are obvious. Rducks prefers
`globals::globalsOf(..., method = "dfs", recursive = TRUE)` when available,
falling back to a `codetools` scan otherwise. This mirrors the futureverse fix:
Henrik Bengtsson's "Future Got Better at Finding Global Variables" describes why
conservative `codetools`-style discovery misses globals needed by parallel
workers and why `globals::findGlobals(..., method = "dfs")` was added:
<https://www.jottr.org/2025/06/23/future-got-better-at-finding-global-variables/>.

For production IPC UDFs with large or subtle dependencies, prefer explicit
`ipc_globals` and `ipc_packages`. Use `ipc_globals_share = "mori"` only for
same-host workers. It is meant for large read-only R globals, not for the SQL
chunk data plane.

A future chunk-data shared-memory mode should be a Rducks-owned raw-buffer
transport: producers share owned input or output byte buffers, send only handles
and byte ranges over NNG, and receivers destroy buffers after receipt/import. It
should not require per-chunk ALTREP creation or R C API calls in DuckDB worker
threads.

## Non-contracts

- `ipc_max_pending` is an admission bound for simultaneous native requests. It
  is not a queued scheduler size.
- There is no collect-many protocol, task id, chunk id, streaming result, or
  out-of-order result reassembly in the current provider.
- IPC work must not silently fall back to same-process execution or R
  serialization.
