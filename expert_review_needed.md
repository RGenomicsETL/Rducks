# Expert review needed: RIPC physical-scan batching options

## Why we need your review

Rducks is an R package plus DuckDB C extension that registers R
functions as DuckDB SQL scalar UDFs. The
`arrow_ipc + multiprocess_parallel` path now works and is safe, but its
batching is bounded by how DuckDB invokes scalar function callbacks. We
need a sincere, severe evaluation of whether there is a practical,
non-invasive way to improve batching for typical DuckDB physical scans,
or whether the current design should be considered the correct ceiling
for scalar UDF semantics.

Please assume the goal is **not** to invent a new large subsystem unless
there is clear evidence that a small extension to the current scheduler
cannot help. We want efficient, conservative options that preserve
safety and explicit semantics.

## Hard constraints

These are non-negotiable constraints for this review:

1.  **DuckDB C API / C extension API only.** Do not propose DuckDB C++
    API hooks.
2.  **No R API from DuckDB worker threads.** Same-process R API work
    must run on the recorded main R thread only.
3.  **No `R_ToplevelExec()` inside DuckDB callbacks.** Current callback
    fences use `R_tryCatchError()` and `R_UnwindProtect()`.
4.  **No hidden fallback.** In particular:
    - no `arrow_c -> arrow_r`;
    - no `arrow_ipc -> serialize()` /
      [`rawConnection()`](https://rdrr.io/r/base/rawConnection.html);
    - no `multiprocess_parallel -> in-process`;
    - no vectorized chunk call silently becoming scalar row-loop in the
      native callback path.
5.  **Scalar UDF callbacks must fill their callback-owned DuckDB output
    vector before returning.** Do not store or use callback-owned DuckDB
    vectors after the callback has returned.
6.  **Database-scoped UDF ownership.** `rducks_release(con)` / detach
    must not drop catalog functions or release catalog-owned closures
    used by sibling connections.
7.  **No package-side pump that pretends DuckDB progress callbacks
    exist.** The current in-process queue is extension-owned and drained
    by legitimate recorded-main-thread callback execution.

## Scope of the issue

The remaining performance/design question is:

> Can RIPC submit/collect batching be improved beyond the set of DuckDB
> scalar UDF callbacks that are simultaneously active and queued,
> without violating scalar-UDF callback lifetime or introducing a hidden
> fallback?

The native-runtime reclamation discussion is **not** the focus here.
R-side registry clearing is handled through runtime anchors/finalizers.
Native runtime entries and extension-owned connections are currently
process-lifetime with accounting diagnostics; we do not want to
overcomplicate that unless DuckDB adds an explicit safe lifecycle hook.

## Current implementation summary

### Execution plan

`rducks_execution_plan("arrow_ipc", "multiprocess_parallel")` registers
UDFs with native evaluator token `RIPC`.

The provider can be:

- `ipc_future_pool` through generic `future`;
- `ipc_mirai_pool`, an experimental persistent mirai provider.

### Native C scheduler

Important files/functions:

- `inst/rducks_extension/src/rducks_worker_queue.c`
  - `RDUCKS_RIPC_COALESCE_WAIT_MS` currently `2U`.
  - `RDUCKS_RIPC_MAIN_WAVE_MAX` currently `64U`.
  - `rducks_queue_submit_ripc_cooperative_on_main()` handles a
    main-thread RIPC callback: submit local chunk, coalesce queued
    worker callbacks, collect the group, then return with its local
    output filled.
  - `rducks_queue_drain_on_main()` drains queued worker callbacks when
    ordinary main-thread execution reaches safe points.
  - `rducks_queue_collect_ripc_group_on_main_impl()` groups queued
    requests by UDF metadata and calls bundle-level `collect_many()` or
    `collect_any()`.
  - `rducks_queue_collect_ripc_group_any_on_main_impl()` writes ready
    results as they arrive for providers with `collect_any()`.
  - `rducks_queue_has_pending()` and the recent post-collect drain let
    the main thread opportunistically drain additional worker callbacks
    that became pending while the local RIPC callback was collecting.

### R provider side

Important files/functions:

- `R/provider_future.R`
  - Future provider returns owned raw Arrow IPC result bytes.
  - No provider-level `collect_any()` is currently exposed for generic
    Future.
- `R/provider_mirai.R`
  - persistent mirai provider with
    start/stop/register/submit/collect/cancel;
  - provider-level backpressure through `ipc_max_pending`;
  - no-deadline waits use mirai blocking wait primitives.
- `R/provider_mirai_engine.R`
  - exposes wrapper-level `collect_any()` for native grouped RIPC
    collection.

### Current data ownership safety

Recent work completed:

- Queued direct `arrow_c` inputs are copied into owned DuckDB chunks
  before main thread R materialization.
- Queued direct `arrow_c` scalar returns use owned Arrow C Data result
  payloads.
- Queued direct `arrow_c` composite returns use owned DuckDB result
  chunks.
- Queued `arrow_r` helper returns import into an owned DuckDB result
  chunk on the main R thread; the waiting worker copies the owned vector
  into callback output.
- RIPC providers now return raw Arrow IPC result bytes; native C
  decodes/imports those bytes into DuckDB output without materializing
  nanoarrow R result arrays in the main process.

### Diagnostics already available

[`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)
reports per-UDF counters including:

- `dispatch_chunks`, `dispatch_rows`;
- `queued_chunks`, `direct_chunks`;
- `arrow_ipc_chunks`;
- `ripc_collect_batches`;
- `ripc_collect_requests`;
- `ripc_collect_max_batch`;
- `ripc_submit_wave_max`;
- `ripc_collect_ready_max`;
- `ripc_inflight_current`, `ripc_inflight_max`.

[`rducks_inproc_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_inproc_stats.md)
reports runtime queue pressure and drain counters.

## Current behavior and suspected ceiling

The current RIPC scheduler can batch chunks only after DuckDB has
invoked scalar UDF callbacks for those chunks. A callback owns exactly
one output vector and cannot return until that vector is filled.
Therefore, Rducks can coalesce:

1.  the local main-thread callback’s chunk;
2.  worker-thread callbacks that have already entered the UDF callback
    and queued their requests;
3.  worker callbacks that become queued while the main thread is
    collecting and that are caught by post-collect draining.

It cannot safely coalesce chunks whose DuckDB callbacks have not started
yet. That appears to be a fundamental scalar-UDF callback limitation,
not just an implementation gap.

Please challenge this conclusion if there is a valid DuckDB C API
mechanism we are missing.

## Options we want evaluated

### Option A: Accept current scalar-UDF ceiling and document it

Keep the current design and treat the open batching item as mostly
resolved. Explain that larger physical-scan batching is out of scope for
scalar UDFs without a different SQL surface.

**Pros**

- No new risk.
- Current behavior is explicit and tested.
- Avoids overfitting scheduler knobs to one benchmark.

**Cons**

- Cheap UDFs may remain dominated by IPC/provider overhead.
- Users may expect `multiprocess_parallel` to scale more automatically
  than it can under scalar callback semantics.

**Expert question**: Is this the honest answer? Should we close the
issue with a clear statement of the scalar-UDF ceiling?

### Option B: Non-public tuning knobs for coalescing and drain budgets

Make currently hard-coded scheduler parameters configurable through
environment variables or internal plan fields:

- coalesce wait in milliseconds;
- max submit wave size;
- post-collect drain max requests;
- possibly a time budget for post-collect drain.

Defaults would remain conservative.

**Pros**

- Small patch.
- Useful for benchmark exploration.
- Does not change provider protocol.

**Cons**

- Easy to make latency worse by waiting too long.
- Public API knobs could become compatibility debt.
- Still cannot batch chunks not yet scheduled by DuckDB.

**Expert question**: Are env-only/internal knobs worth adding now, or
would they mostly create noise without solving the real limitation?

### Option C: Adaptive bounded post-collect draining

Generalize the recent post-collect drain into a bounded adaptive loop:

- drain while pending exists;
- stop after N requests or T milliseconds;
- perhaps continue only for RIPC requests matching the same UDF/provider
  shape.

**Pros**

- Still non-invasive.
- Helps callbacks that arrive during provider collection.
- Can be bounded and measurable with existing counters.

**Cons**

- The main-thread callback’s own output is already filled; extra
  draining delays its return to DuckDB.
- Could harm latency for mixed workloads.
- Still limited to active callbacks.

**Expert question**: Is this worth implementing, and what should the
bounds be? Should it drain all queued request types or only RIPC
requests?

### Option D: Add `collect_any()` to the generic Future provider

The mirai provider has `collect_any()`. The generic Future wrapper
currently uses
`collect_many()`/[`future::value()`](https://future.futureverse.org/reference/value.html)
semantics. A Future `collect_any()` could poll
[`future::resolved()`](https://future.futureverse.org/reference/resolved.html)
with a small sleep/budget and return ready payloads.

**Pros**

- Gives generic Future some of the mirai ready-result behavior.
- Could reduce head-of-line blocking within grouped collection.

**Cons**

- `future` lacks a clean blocking race primitive in the generic API.
- A scan/sleep loop may be inefficient and harder to justify after we
  removed similar no-deadline polling from mirai.
- More R-side scheduler code with uncertain payoff.

**Expert question**: Is a bounded Future poll acceptable here, or should
`collect_any()` remain a mirai-provider advantage?

### Option E: Provider-level microbatching envelope

Submit multiple IPC chunks in a single provider task. The worker
evaluates a list of IPC payloads and returns a list of result payloads.

**Pros**

- Reduces provider scheduling overhead per chunk.
- Could be useful for cheap R functions.

**Cons**

- Protocol change across Future and mirai providers.
- More complex error mapping: one task can contain multiple
  chunks/output vectors.
- Worse load balancing if one microbatch contains slow chunks.
- Still only works for chunks whose callbacks are already active/queued.
- May increase memory pressure by holding multiple IPC payloads/results.

**Expert question**: Is this too invasive for the likely gain? If not,
what is a minimal microbatch envelope that preserves per-chunk error
semantics?

### Option F: New explicit batched SQL/table-function surface

Add a separate API that is honest about batched execution instead of
pretending scalar UDF callbacks can batch arbitrary physical-scan
chunks.

**Pros**

- Only path that could own a larger batch intentionally.
- Avoids fighting scalar callback lifetime semantics.

**Cons**

- Invasive API design.
- Not a transparent replacement for scalar UDFs.
- Requires a new semantic contract and likely much more testing.

**Expert question**: Should this be considered the only real path to
large-batch parallel R evaluation, and deferred until there is clear
demand?

## Options that seem unsafe or unacceptable

Please confirm or correct these rejections:

1.  **Returning from scalar UDF callback before output writeback**:
    unsafe because callback-owned output vector lifetime ends with the
    callback.
2.  **Storing DuckDB vectors for later writeback**: unsafe for the same
    reason.
3.  **Calling R from worker threads**: violates R API thread safety.
4.  **Installing a package-side pump/progress loop**: fragile and not a
    real DuckDB execution hook.
5.  **Silently falling back to in-process or scalar row-loop paths**:
    violates the no-hidden-fallback contract.

## What we want from the review

Please be severe and specific:

1.  Identify any incorrect assumption about DuckDB C scalar UDF callback
    lifetime, local state, or vector ownership.
2.  Say whether larger physical-scan batching is fundamentally
    impossible for the scalar UDF API under these constraints.
3.  Rank Options A-F by risk/reward.
4.  Recommend the smallest next change, if any.
5.  Call out any current scheduler code that looks unsafe,
    overcomplicated, or likely to deadlock/starve.
6.  Suggest measurements that would prove whether a non-invasive change
    helped.

## Suggested measurements for any proposed change

For each candidate change, compare at least:

- `arrow_ipc + ipc_future_pool` cheap vectorized UDF;
- `arrow_ipc + ipc_mirai_pool` cheap vectorized UDF;
- one expensive/sleeping UDF where parallelism should help;
- single worker vs two workers;
- low vs high DuckDB thread count.

Record:

- wall time;
- [`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)
  counters listed above;
- [`rducks_inproc_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_inproc_stats.md)
  queue/drain counters;
- provider task counts and pending/max pending when available;
- memory growth if microbatching is considered.

## Current recommendation from maintainers before review

Our current bias is:

1.  Close native runtime reclamation as accepted/process-lifetime, not
    blocked.
2.  For RIPC batching, prefer Option A plus maybe internal-only
    tuning/adaptive bounds (Options B/C) if an expert sees a clear
    low-risk win.
3.  Avoid microbatching or a new SQL surface until measurements show
    current scheduler overhead is the dominant user-facing problem.
