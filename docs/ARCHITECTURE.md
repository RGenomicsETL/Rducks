# Rducks Architecture

Rducks is designed as an R package plus a loaded DuckDB extension for registering
R functions as DuckDB UDFs.

## Core layers

1. **R wrapper layer**
   - validates user-facing registration calls
   - preserves R callback functions
   - loads/enables the DuckDB extension on a connection

2. **DuckDB extension layer**
   - owns SQL registration and DuckDB function objects
   - stores per-UDF metadata in `extra_info`
   - exposes one generic DuckDB scalar callback per execution family
   - exports/imports chunks through DuckDB Arrow C Data APIs
   - manages a synchronous calling-R-thread queue for worker-thread callback requests

3. **nanoarrow bridge layer**
   - canonical chunk marshalling through DuckDB `data_chunk` ⇄ Arrow C Data APIs
   - typed Rducks conversion rules for exact/exotic values
   - scalar adapter that invokes the R callback once per DuckDB row

## Scalar UDF execution model

```text
DuckDB
  -> rducks_generic_scalar_callback(info, input, output)
      -> metadata from extra_info
      -> DuckDB chunk -> Arrow C Data export
      -> nanoarrow-backed scalar adapter on the calling R thread
      -> queued synchronous request if on a DuckDB worker
      -> calling R thread drains queued requests without workers touching the R API
      -> Arrow C Data -> DuckDB chunk import
```

## Pump model

A DuckDB worker must never call R directly. Worker paths enqueue a native request
and wait. The calling-R-thread pump drains requests, calls R with error
containment, writes the native result slot, then signals the waiting worker.

Current pump triggers are deliberately narrow: direct calling-R-thread UDF
entry/exit drains queued worker requests. Future hooks can add DuckDB progress
callbacks or input-handler fallbacks once those paths are proven under blocking
UDF loads.

## First safe mode

The first direct-callback scalar mode uses:

```sql
SET external_threads=1;
PRAGMA threads=1;
```

Rducks requires this mode before registering direct R callbacks; that
registration-time check is the primary guard. The R package records a thread
token in package state at namespace load and passes it to the extension through
an internal SQL function during `rducks_enable()`. The extension checks the
execution thread before every callback. Worker-thread chunks enqueue a
synchronous request and wait; the calling R thread drains those requests and
signals the waiting worker after the output vector has been filled. Broader
multi-threaded sync UDF support still needs stress testing under blocking UDF
loads before being documented as stable.

## nanoarrow direction and lifetime model

Rducks should follow Arrow C Data ownership rules in R terms: use named
`externalptr` objects, explicit owner/protected slots, idempotent finalizers, and
move-only consumption. A worker-to-main request that carries Arrow C Data should
answer four questions at every boundary:

- who owns the `ArrowArray`/`ArrowSchema`/request object now
- whether the pointer is borrowed from DuckDB memory or owns independent buffers
- who calls `release()` if the object is abandoned
- who nulls `release` after the object has been consumed by DuckDB or R

Borrowed DuckDB chunk views must not outlive the DuckDB callback stack that
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
