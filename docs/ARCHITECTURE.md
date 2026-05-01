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
      -> DuckDB chunk -> Arrow C Data export
      -> nanoarrow-backed scalar adapter on the calling R thread
      -> Arrow C Data -> DuckDB chunk import
```

## Thread model

A DuckDB worker must never call R directly. The supported public configuration
therefore keeps direct R function execution on the calling R thread by requiring
`external_threads=1` and `PRAGMA threads=1` at registration. Native request-queue
code is an internal guard/future integration path, not a documented
multi-threaded execution contract.

## First safe mode

The first direct-R-function scalar mode uses:

```sql
SET external_threads=1;
PRAGMA threads=1;
```

Rducks requires this mode before registering direct R functions; that
registration-time check is the primary guard. The R package records a thread
token in package state at namespace load and passes it to the extension through
an internal SQL function during `rducks_enable()`. The extension checks the
execution thread before every R function execution. Broader multi-threaded sync
UDF support still needs a proven pump/progress mechanism under blocking UDF loads
before being documented as stable.

## nanoarrow direction and lifetime model

Rducks should follow Arrow C Data ownership rules in R terms: use named
`externalptr` objects, explicit owner/protected slots, idempotent finalizers, and
move-only consumption. Any future worker-to-calling-thread request that carries
Arrow C Data should answer four questions at every boundary:

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
