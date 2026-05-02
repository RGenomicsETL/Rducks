# Rducks Architecture

Rducks is designed as an R package plus a loaded DuckDB extension for registering
R functions as DuckDB UDFs.

## Core layers

1. **R wrapper layer**
   - validates user-facing registration calls
   - prepares R function wrappers for registration
   - loads/enables the DuckDB extension on a connection

2. **DuckDB extension layer**
   - owns SQL registration and DuckDB function objects
   - stores per-UDF metadata in `extra_info`
   - exposes one generic DuckDB scalar-function entry point per execution family
   - exports/imports chunks through DuckDB Arrow C Data APIs
   - preserves R functions while DuckDB owns registered UDF metadata

3. **nanoarrow bridge layer**
   - canonical chunk marshalling through DuckDB `data_chunk` ⇄ Arrow C Data APIs
   - typed Rducks conversion rules for exact/exotic values
   - scalar adapter that invokes the R function once per DuckDB row

## Scalar UDF execution model

```text
DuckDB
  -> rducks_r_scalar_udf(info, input, output)
      -> metadata from extra_info
      -> eval_mode = "R": DuckDB chunk -> Arrow C Data -> R row-loop adapter
      -> eval_mode = "RC": native C row-loop adapter, with direct DuckDB vector reads/writes where implemented
```

Both scalar evaluators call the R function once per logical row. `eval_mode =
"RC"` moves row iteration, call construction, NULL handling, return checking,
and direct DuckDB vector reads/writes into C for supported scalar storage; the
user function itself is still evaluated by R, so S3/S7 dispatch, RNG, lexical
scoping, and side effects keep ordinary R semantics.

## Thread model

A DuckDB worker must never call R directly. The supported public configuration
therefore keeps scalar-mode R UDF execution on the calling R thread by requiring
`external_threads=1` and `PRAGMA threads=1` at registration. If DuckDB later
enters a scalar Rducks UDF on a non-calling execution thread, the extension
errors immediately rather than queueing work through an unproven main-thread
pump.

Thread-safety means preserving this invariant, not making R itself callable from
DuckDB worker threads. A future concurrent UDF design should declare that chunks
may be evaluated concurrently, while the execution plan chooses how that happens
(for example, an out-of-process compute backend). The public UDF contract should
say what concurrency is allowed, not expose process pools, worker threads, or a
specific queue implementation as scalar-function semantics.

## R API and DuckDB-worker boundary discipline

Keep the following layers separate when changing the native path:

1. **DuckDB-only layer**: may inspect/copy DuckDB vectors, build owned native
   request/result buffers, enqueue native work, wait, and write DuckDB output.
   It must not allocate `SEXP`s, call `Rf_*`, create nanoarrow R external
   pointers, preserve/release R objects, or evaluate R calls.
2. **R-thread layer**: may allocate R objects, call R functions, create
   nanoarrow external pointers, run return validation, and release preserved R
   objects. It must run on the recorded R thread.
3. **Ownership bridge**: moves data between those layers through owned C memory
   such as copied Arrow C Data buffers or explicit native column buffers. It
   must not pass borrowed DuckDB vectors or transient `SEXP` objects across
   threads.

The current RC path is deliberately a calling-R-thread path and therefore mixes
R API calls with direct DuckDB vector reads/writes in one callback-local loop.
That is acceptable only because off-thread entry is rejected before execution.
Do not reuse RC direct-buffer helpers as worker-safe building blocks without
first splitting them along the boundaries above.

## First safe mode

The supported scalar-mode R UDF path uses:

```sql
SET external_threads=1;
PRAGMA threads=1;
```

Rducks requires this mode before registering scalar-mode R UDFs; that
registration-time check is the primary guard. The R package records a thread
token in package state at namespace load and passes it to the extension through
an internal SQL function during `rducks_enable()`. The extension checks the
execution thread before every R function execution. Broader multi-threaded sync
UDF support still needs a proven pump/progress mechanism under blocking UDF loads
before being documented as stable.

## nanoarrow direction and lifetime model

Rducks should follow Arrow C Data and DuckDB vector ownership rules in R terms:
use named `externalptr` objects, explicit owner/protected slots, idempotent
finalizers, and move-only consumption. Borrowed DuckDB `duckdb_data_chunk` and
`duckdb_vector` pointers are valid only during the native UDF callback. RC-mode
per-row R arguments are fresh R objects, not mutable views into DuckDB storage;
this is required because arbitrary R functions may retain an argument object
after returning. Direct RC paths for supported ordinary, exact/exotic, decimal,
UUID, interval, and bit scalar storage target DuckDB-owned vectors and use
DuckDB's assignment APIs for variable-width values so Rducks does not retain R or
DuckDB buffer pointers across the callback boundary.

Any future worker-to-calling-thread request that carries Arrow C Data should
answer four questions at every boundary:

- who owns the `ArrowArray`/`ArrowSchema`/request object now
- whether the pointer is borrowed from DuckDB memory or owns independent buffers
- who calls `release()` if the object is abandoned
- who nulls `release` after the object has been consumed by DuckDB or R

Borrowed DuckDB chunk views must not outlive the DuckDB UDF stack that
created them. If a future pump allows the worker to return before the calling R
thread has consumed the input, the request must copy into owned nanoarrow buffers
instead of exporting a borrowed view.

Rducks uses the in-process DuckDB Arrow C Data API plus nanoarrow for the scalar
adapter and should reuse that path for any future vectorized UDFs:

- `ArrowArray`
- `ArrowSchema`
- `ArrowArrayStream`

This is distinct from Arrow IPC, which is for transport/storage rather than the
zero-copy in-process path. The R package uses `nanoarrow` for R-side pointer
objects and ownership helpers; it does not depend on the R `arrow` package.
