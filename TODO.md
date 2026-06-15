# Rducks TODO

This file is development-facing. Keep user-facing changes in `NEWS.md` and
README/docs. Do not use this file as a historical changelog; it should describe
what still needs doing.

- [ ] Implement native runtime reclamation if DuckDB exposes a safe
  database-close callback or removable extension-owned connection lifecycle
  hook.
  - Acceptance: repeated connect/register/disconnect/reconnect loops cannot leak
    unbounded native runtime entries or retain stale native backend state.

- [ ] Improve batching beyond small waves for typical DuckDB physical scans.
  - The `ipc` worker pool already has provider-level backpressure
    (`ipc_max_pending`), collect-any result handling so ready payloads are
    written back as they arrive, and an opportunistic post-collect drain of the
    extension-owned queue. What remains is larger physical-scan batching beyond
    the set of simultaneously active callbacks.
