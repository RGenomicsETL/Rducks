# Rducks Architecture

Rducks is designed as an R package plus a loaded DuckDB extension for registering
R functions as DuckDB UDFs.

## Core layers

1. **R wrapper layer**
   - validates user-facing registration calls
   - preserves R callback functions
   - generates shape-specific C wrapper source through Rtinycc
   - loads/enables the DuckDB extension on a connection

2. **DuckDB extension layer**
   - owns SQL registration and DuckDB function objects
   - stores per-UDF metadata in `extra_info`
   - exposes one generic DuckDB scalar callback per execution family
   - manages a main-R-thread pump for R callback requests

3. **Generated wrapper layer**
   - one TinyCC/Rtinycc-compiled wrapper per UDF shape
   - typed row/chunk marshalling between DuckDB vectors and Rducks callback args
   - no R API calls from DuckDB worker threads

## Scalar UDF execution model

```text
DuckDB
  -> rducks_generic_scalar_callback(info, input, output)
      -> metadata from extra_info
      -> vector/chunk decoding
      -> generated shape wrapper
          -> direct R call if on R main thread
          -> queued sync request if on a DuckDB worker
      -> output vector write-back
```

## Pump model

A DuckDB worker must never call R directly. Worker paths enqueue a native request
and wait. A main-thread pump drains requests, calls R with error containment,
writes the native result slot, then signals the waiting worker.

Pump triggers are staged deliberately:

- direct main-thread UDF entry/exit
- explicit `rducks_pump()`
- DuckDB progress callback hook where available
- optional input-handler fallback only as opportunistic support

## First safe mode

The first direct-callback scalar mode uses:

```sql
PRAGMA threads=1;
```

Rducks requires this mode before registering direct R callbacks. Multi-threaded
sync UDFs require the pump queue to be proven under blocking UDF loads before
being documented as stable.

## Arrow/nanoarrow direction

Rducks should use the in-process Arrow C Data Interface for batch UDFs:

- `ArrowArray`
- `ArrowSchema`
- `ArrowArrayStream`

This is distinct from Arrow IPC, which is for transport/storage rather than the
zero-copy in-process path. The R package may use the optional `nanoarrow` package
for R-side pointer objects and ownership helpers.
