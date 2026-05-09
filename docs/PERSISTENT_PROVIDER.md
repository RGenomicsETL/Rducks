# Persistent IPC Provider

Rducks has one IPC provider shape for `arrow_ipc + multiprocess_parallel`:
`ipc_nng_pool`.

The current implementation is intentionally narrower than a general task queue:
workers are persistent, but each DuckDB scalar-UDF callback performs one
synchronous NNG request/reply. Native code opens a request socket, sends a v1
frame, waits under `ipc_timeout`, imports the Arrow IPC result into DuckDB, and
then returns from the callback. There is no collect-many queue, task id, chunk
id, or implemented `ipc_max_pending` backpressure limit yet.

The provider contract is explicit:

- workers are persistent R processes reachable over NNG/nanonext endpoints;
  Rducks can launch local worker loops with mirai daemons using generated
  `abstract`, `ipc`, `unix`, `tcp`, or `ws` endpoints, or use explicit
  externally managed NNG endpoint URLs directly;
- each UDF is registered once per provider pool;
- workers receive the UDF closure, declared types, NULL/error policy, output
  schema description, packages, and discovered globals at registration time;
- each v1 chunk request carries a request type, UDF id, row count, and owned
  Arrow IPC input bytes;
- each v1 response returns status, plain error text, and owned Arrow IPC result
  bytes;
- DuckDB scalar callbacks fill callback-owned DuckDB output before returning and
  do not call the R API on DuckDB worker threads.

`ipc_max_pending` remains a reserved compatibility/diagnostic field until a
future provider implements a true submit/collect queue with backpressure.

Rducks does not silently route IPC work through a different provider or fall
back to same-process evaluation.
