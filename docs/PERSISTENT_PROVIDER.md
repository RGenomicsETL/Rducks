# Persistent IPC Provider

Rducks has one IPC provider shape for `arrow_ipc + multiprocess_parallel`:
`ipc_nng_pool`.

The provider contract is explicit:

- workers are persistent R processes reachable over NNG/nanonext endpoints; Rducks can launch local worker loops with mirai daemons using generated `abstract`, `ipc`, `unix`, `tcp`, or `ws` endpoints, or use explicit externally managed NNG endpoint URLs directly;
- each UDF is registered once per provider pool;
- workers receive the UDF closure, declared types, NULL/error policy, output
  schema description, packages, and discovered globals at registration time;
- each chunk request carries a UDF id, row count, and owned Arrow IPC input
  bytes;
- each response returns owned Arrow IPC result bytes or structured error text;
- DuckDB scalar callbacks fill callback-owned DuckDB output before returning and
  do not call the R API on DuckDB worker threads.

Rducks does not silently route IPC work through a different provider or fall
back to same-process evaluation.
