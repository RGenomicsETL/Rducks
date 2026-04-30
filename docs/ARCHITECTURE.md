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
   - performs current direct row-mode marshalling and R callback execution
   - will manage a main-R-thread pump for worker-thread callback requests

3. **Arrow/nanoarrow bridge layer**
   - planned canonical chunk marshalling through DuckDB `data_chunk` ⇄ Arrow APIs
   - typed Rducks conversion rules for exact/exotic values
   - batch callback paths that avoid one R call per row

## Scalar UDF execution model

```text
DuckDB
  -> rducks_generic_scalar_callback(info, input, output)
      -> metadata from extra_info
      -> vector/chunk decoding
      -> direct R call if on R main thread
      -> queued sync request if on a DuckDB worker once the pump exists
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
