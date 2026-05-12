# Shared-memory IPC design notes

Rducks has two separate same-host shared-memory questions. They must not be
merged into one capability flag because their ownership and failure modes differ.

## Current status

| Track | Status | Contract |
| --- | --- | --- |
| Large read-only R globals | Implemented for managed local IPC workers with `ipc_globals_share = "mori"`. | Rducks applies `mori::share()` to selected globals before worker registration and keeps the shared references anchored for the registered UDF lifetime. |
| SQL chunk data plane | Not implemented. | Current `arrow_ipc + multiprocess_parallel` requests and responses carry owned Arrow IPC raw bytes over NNG. |

The default managed mirai backend is same-host and can use mori-backed global
sharing. It does **not** currently support SQL chunk shared-memory handles. The
external endpoint backend may point to remote processes and supports neither
mori-global assumptions nor chunk shared-memory handles.

## Why mori is not the chunk data-plane design

`mori` is useful for long-lived R objects because the share operation happens at
registration time and the shared references are reused by workers. Per-query or
per-chunk SQL data would require repeatedly creating, serializing, receiving,
and collecting short-lived ALTREP/shared objects. That introduces lifecycle churn
on the critical path and would still require clear cancellation/crash cleanup
rules. It should not be exposed as a data-plane API without measurements showing
it beats the current owned Arrow IPC byte path.

Use `tools/benchmark_ipc_data_plane.R` to gather local evidence before adding any
user-facing shared-memory data-plane option. The benchmark reports:

- current Arrow IPC encode/decode timings and byte sizes;
- current NNG wire-frame copy overhead for those bytes;
- when `mori` is installed, per-chunk `mori::share()` reference creation,
  serialization size, and unserialization timings.

Example quick run:

```sh
Rscript tools/benchmark_ipc_data_plane.R --rows=1024,8192 --reps=3
```

## Candidate chunk-handle protocol

A future chunk data plane should be Rducks-owned and handle based:

1. The producer allocates or reuses a same-host shared buffer owned by Rducks,
   not by the R garbage collector.
2. The producer writes an Arrow IPC payload or Arrow-compatible buffers into the
   shared region and marks the written range read-only to workers where the
   platform allows it.
3. The NNG message carries only control metadata, for example:
   `{transport="shm", name, offset, length, schema_version, request_id,
   direction, checksum?}`.
4. The consumer maps or opens the region, imports/copies the requested range,
   and sends an acknowledgement or error for `request_id`.
5. The owner releases the region/range only after acknowledgement, timeout, or
   cancellation cleanup. Crash recovery must tolerate leaked OS resources and
   remove stale files/names on the next provider cleanup.

Required invariants:

- same-host only; remote endpoints continue using byte payloads;
- no R API calls from DuckDB worker threads;
- no process-local pointers in protocol messages;
- query-critical buffer lifetime must not depend solely on R GC;
- backend choice must not change SQL type mapping, NULL behavior, or result
  shapes;
- the byte path remains the fallback and the compatibility baseline.

## Capability names

Provider capability metadata distinguishes the two tracks:

- `supports_mori_global_sharing`: backend can safely use mori shared references
  for long-lived globals managed by Rducks.
- `supports_chunk_shared_memory_handles`: backend can use Rducks-owned shared
  chunk handles for SQL input/result data. This is currently `FALSE` for all
  built-in backends.
- `supports_shared_memory_handles`: legacy aggregate flag retained for internal
  compatibility. Treat it as chunk-handle support and keep it `FALSE` until the
  chunk data plane exists.
