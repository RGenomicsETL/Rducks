# Rducks TODO

This file is development-facing. Keep user-facing changes in `NEWS.md` and
README/docs. Do not use this file as a historical changelog; it should describe
what still needs doing.

- [ ] Implement native runtime reclamation if DuckDB exposes a safe
  database-close callback or removable extension-owned connection lifecycle
  hook.
  - Acceptance: repeated connect/register/disconnect/reconnect loops cannot leak
    unbounded native runtime entries or retain stale native backend state.

- [ ] Replace the generic physical-layout VARIANT adapter if DuckDB publishes
  dedicated stable C extension accessors.
  - Current: Rducks obtains the canonical logical type from the SQL binder,
    dynamically probes every physical child with generic struct/list APIs, and
    fails closed when the runtime layout differs.
  - Acceptance: dedicated upstream accessors cover canonical type cloning plus
    direct and IPC vector reads/writes without weakening exact-version ABI or
    registration gates; retain the current scalar/vectorized, nested, aggregate,
    dynamic-bind, NULL, malformed-storage, and worker round-trip tests.

- [ ] Improve batching beyond small waves for typical DuckDB physical scans.
  - The `ipc` worker pool already has provider-level backpressure
    (`ipc_max_pending`), collect-any result handling so ready payloads are
    written back as they arrive, and an opportunistic post-collect drain of the
    extension-owned queue. What remains is larger physical-scan batching beyond
    the set of simultaneously active callbacks.
