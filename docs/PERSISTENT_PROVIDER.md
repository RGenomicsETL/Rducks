# Persistent IPC Provider

Rducks has one IPC provider shape for `arrow_ipc + multiprocess_parallel`:
`ipc_nng_pool`.

The current implementation is intentionally narrower than a general task queue:
workers are persistent, but each DuckDB scalar-UDF callback performs one
synchronous NNG request/reply through a native per-UDF client pool. Native code
uses persistent request sockets, sends a v1 frame, waits under `ipc_timeout`,
imports the Arrow IPC result into DuckDB, and then returns from the callback.
There is no collect-many queue, task id, or chunk id yet. `ipc_max_pending` is
enforced as a native pending/in-flight admission limit for this synchronous
callback path, not as a queued submit/collect scheduler.

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

`ipc_max_pending` bounds the number of native requests admitted to a registered
UDF's NNG client pool. It is not a task queue size and does not add collect-many
semantics.

Rducks does not silently route IPC work through a different provider or fall
back to same-process evaluation.
