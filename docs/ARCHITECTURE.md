# Rducks Architecture

Rducks is designed as an R package plus a loaded DuckDB extension for registering
R functions as DuckDB UDFs.

See [Execution Plans And Validation Checklist](EXECUTION_PLANS.md) for the target
separation between UDF semantics, marshalling implementation, concurrency model,
the hard `arrow_r + serial` reference implementation, and the no-fallback rule.

## Core layers

1. **R wrapper layer**
   - validates user-facing registration calls
   - prepares R function wrappers for registration
   - loads/enables the DuckDB extension on a connection

2. **DuckDB extension layer**
   - owns SQL registration and DuckDB function objects
   - keeps extension runtime state in a per-loaded-database registry, not a singleton connection
   - stores per-UDF metadata in `extra_info`
   - uses DuckDB C extension bind/init/local-state callbacks for per-query/per-worker state
   - exposes one generic DuckDB scalar-function entry point per execution family
   - exports/imports chunks through DuckDB Arrow C Data APIs
   - preserves R functions while DuckDB owns registered UDF metadata

3. **nanoarrow bridge layer**
   - canonical chunk marshalling through DuckDB `data_chunk` ⇄ Arrow C Data APIs
   - typed Rducks conversion rules for exact/exotic values
   - scalar adapter that invokes the R function once per DuckDB row
   - vectorized adapter that invokes the R function once per DuckDB chunk

## Scalar and vectorized UDF execution model

```text
DuckDB
  -> rducks_r_scalar_udf(info, input, output)
      -> metadata from extra_info
      -> mode = "scalar", plan marshalling = "arrow_r": DuckDB chunk -> Arrow C Data -> R row-loop adapter
      -> mode = "scalar", plan marshalling = "arrow_c": native C row-loop adapter, with direct DuckDB vector reads/writes where implemented
      -> mode = "vectorized", plan marshalling = "arrow_r": DuckDB chunk -> Arrow C Data -> one R call over vectors/list-columns
      -> mode = "scalar", plan marshalling = "arrow_ipc": DuckDB chunk -> Arrow IPC -> Future worker row loop -> Arrow IPC result
      -> mode = "vectorized", plan marshalling = "arrow_ipc": DuckDB chunk -> Arrow IPC -> Future worker chunk call -> Arrow IPC result
```

All scalar evaluators call the R function once per logical row. `arrow_c` moves
row iteration, call construction, NULL handling, return checking, and direct
DuckDB vector reads/writes into C for supported scalar storage; the user function
itself is still evaluated by R, so S3/S7 dispatch, RNG, lexical scoping, and side
effects keep ordinary R semantics. `arrow_ipc` loops rows inside a Future worker.
Vectorized mode calls the R function once per DuckDB chunk and supports
`arrow_r`, `arrow_c`, and `arrow_ipc` plans without falling back between them.

## Thread model

A DuckDB worker must never call R directly. The registration-safe default keeps
R UDF execution on the calling R thread by requiring
`external_threads=1` and `PRAGMA threads=1` at registration. After registration,
`rducks_enable_inproc()` can switch the connection to the in-process queued
backend. In that backend, non-main UDF callbacks submit requests to an
extension-owned queue and wait while the recorded main R execution lane drains
those requests and performs all R API work. There is no package-side queue,
hidden progress callback, or idle-loop pump.

Thread-safety means preserving this invariant, not making R itself callable from
DuckDB worker threads. In-process queuing is a same-process scheduling and
liveness mechanism, not a parallel-R performance feature: R calls remain
serialized on the main R lane. The public UDF contract should say what
concurrency is allowed, not expose process pools, worker threads, mirai daemons,
or a specific dispatcher implementation as scalar-function semantics.

## R API and DuckDB-worker boundary discipline

Keep the following layers separate when changing the native path:

1. **DuckDB-only layer**: may inspect/copy DuckDB vectors, build owned native
   request/result buffers, hand work to an explicit extension-owned runtime,
   wait, and write DuckDB output.
   It must not allocate `SEXP`s, call `Rf_*`, create nanoarrow R external
   pointers, preserve/release R objects, or evaluate R calls.
2. **R-thread layer**: may allocate R objects, call R functions, create
   nanoarrow external pointers, run return validation, and release preserved R
   objects. It must run on the recorded R thread.
3. **Ownership bridge**: moves data between those layers through owned C memory
   such as copied Arrow C Data buffers or explicit native column buffers. It
   must not pass borrowed DuckDB vectors or transient `SEXP` objects across
   threads.

The current `arrow_c` scalar execution helpers are deliberately main-R-lane
helpers and therefore mix R API calls with direct DuckDB vector reads/writes in
one callback-local loop. In the `serial` concurrency plan, DuckDB enters them
directly on the recorded R thread. In the `inproc_concurrent` plan, an off-main
callback must queue first; the main R lane drains the request and only then runs
those helpers. Do not reuse `arrow_c` direct-buffer helpers as worker-safe
building blocks without first splitting them along the boundaries above.

## Prepared scalar and vectorized execution plans

The `arrow_r` and `arrow_c` scalar row-loop code is split into explicit phases:

1. prepare typed R inputs from an Arrow C Data chunk;
2. evaluate the scalar R function row-by-row;
3. validate each scalar return;
4. build an Arrow C Data result chunk.

`arrow_r` calls this engine through an R wrapper on the recorded R lane.
`arrow_c` keeps its current main-lane direct-buffer fast path and its C row-loop
fallback, but the fallback bundle now carries the same prepare/result helpers
plus an R engine object. This does not rule out a future threaded `arrow_c`
implementation; it only describes the path that is safe today. A threaded native
backend must split worker-safe DuckDB/vector work from any R API or `SEXP` work,
then cross an owned-buffer transport boundary before R-thread evaluation, or be
a genuinely pure-native evaluator with no R callback. This keeps scalar
semantics independent from the transport that delivered a chunk while preserving
the marshalling-plan split. Vectorized mode reuses the same prepare/result
phases but replaces row-wise evaluation with one call over column-shaped R
arguments. With `null_handling = "default"`, only rows with no top-level SQL NULL
inputs are evaluated and SQL NULL rows are scattered back into the DuckDB result;
with `null_handling = "special"`, all rows are passed through with the same
NA/NULL shapes used by scalar mode.

Internally the current concurrency backends are:

- `serial`: default behavior; DuckDB calls the UDF on the recorded R thread and
  may use direct `arrow_c` vector reads/writes.
- `inproc_concurrent`: same-address-space queued dispatch. A worker-side UDF
  callback submits the current chunk request to the per-runtime queue and waits;
  the main R execution lane drains the request, calls R, writes the DuckDB
  output vector, and signals the waiter. This currently relies on the UDF
  callback staying alive while the borrowed DuckDB chunk/output pointers are
  processed; workers must not return before the main lane has consumed the
  request. Direct `arrow_c` helpers remain main-lane-only unless split into pure
  native worker-safe phases.
- `multiprocess_parallel`: out-of-process execution through the current generic
  Future backend. The scalar-UDF callback implementation serializes chunk
  payloads with Arrow IPC so workers receive raw task/result payloads rather
  than DuckDB-owned pointers or session-bound R objects. It is real UDF
  execution, but it is bounded by DuckDB's synchronous callback contract; the
  production performance path should own the source and pre-split it into Arrow
  IPC chunk tasks before submission.

Arrow C Data remains the canonical in-process marshalling layer. Arrow IPC is
reserved for serialized/out-of-process transport and owned task payloads, not
for the ordinary callback-local DuckDB ⇄ R handoff.

## Registration-safe mode

The registration-safe scalar-mode R UDF setup uses:

```sql
SET external_threads=1;
PRAGMA threads=1;
```

Rducks requires this setup before registering scalar-mode R UDFs; that
registration-time check is the primary guard. The R package records a thread
token in package state at namespace load and passes it to the extension through
an internal SQL function during `rducks_enable()`. The extension checks the
execution thread before every R function execution. `rducks_enable_inproc()` is
the explicit opt-in for queued same-process dispatch after registration, and can
also adjust DuckDB's `threads`/`external_threads` settings for that queued phase.
The queue has timeout/error paths so a missing main-lane drain fails rather than
waiting indefinitely.

## nanoarrow direction and lifetime model

Rducks should follow Arrow C Data and DuckDB vector ownership rules in R terms:
use named `externalptr` objects, explicit owner/protected slots, idempotent
finalizers, and move-only consumption. Borrowed DuckDB `duckdb_data_chunk` and
`duckdb_vector` pointers are valid only during the native UDF callback.
`arrow_c` scalar per-row R arguments are fresh R objects, not mutable views into
DuckDB storage; this is required because arbitrary R functions may retain an
argument object after returning. Direct `arrow_c` paths for supported ordinary,
exact/exotic, decimal, UUID, interval, and bit scalar storage target
DuckDB-owned vectors and use
DuckDB's assignment APIs for variable-width values so Rducks does not retain R or
DuckDB buffer pointers across the callback boundary.

Any worker-to-calling-thread request that carries Arrow C Data should answer
four questions at every boundary:

- who owns the `ArrowArray`/`ArrowSchema`/request object now
- whether the pointer is borrowed from DuckDB memory or owns independent buffers
- who calls `release()` if the object is abandoned
- who nulls `release` after the object has been consumed by DuckDB or R

Borrowed DuckDB chunk views must not outlive the DuckDB UDF stack that created
them. The current in-process queue is synchronous: the worker waits until the
main R lane consumes the request. If a future dispatcher allows the worker to
return before that consumption, the request must copy into owned nanoarrow
buffers instead of exporting a borrowed view.

Rducks uses the in-process DuckDB Arrow C Data API plus nanoarrow for both the
scalar and vectorized adapters:

- `ArrowArray`
- `ArrowSchema`
- `ArrowArrayStream`

This is distinct from Arrow IPC, which is for transport/storage rather than the
zero-copy in-process path. The R package uses `nanoarrow` for R-side pointer
objects and ownership helpers; it does not depend on the R `arrow` package.
