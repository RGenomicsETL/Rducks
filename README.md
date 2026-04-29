# Rducks

Rducks is intended to be an R package plus loaded DuckDB extension for
registering R functions as DuckDB user-defined functions.

This repo is **not yet a working R UDF extension**. There is deliberately no
fake `dbGetQuery()` example here until a real DuckDB extension path exists and
is covered by tests.

## Current implemented pieces

- R package skeleton and native R callback token preservation.
- Type-token normalization helpers for planned scalar signatures.
- Architecture notes for the DuckDB extension and Rtinycc-generated wrapper
  path.

## Not implemented yet

- Loading a bundled `rducks.duckdb_extension` artifact.
- Registering a SQL UDF visible to DuckDB.
- The generic DuckDB scalar bridge.
- The main-thread pump queue that releases DuckDB workers waiting on R.
- Arrow/nanoarrow batch UDFs.

Until those exist, `rducks_enable()`, `rducks_register()`, and `rducks_pump()`
fail explicitly instead of pretending to work.

## Intended architecture

```text
DuckDB extension loaded into a connection
  -> generic DuckDB scalar/table bridge
  -> Rtinycc-generated per-shape trampolines
  -> main-R-thread callback pump
  -> R callback result written back to DuckDB vectors
```

## Why Rtinycc?

DuckDB scalar callbacks use one fixed C ABI, but R UDFs have arbitrary type
shapes. Rtinycc is useful as the dynamic shape compiler: Rducks can generate a
small C wrapper per UDF signature instead of interpreting every value through a
large runtime switch.

## Why nanoarrow?

Scalar UDFs do not require nanoarrow. Arrow-batch UDFs should use the in-process
Arrow C Data Interface (`ArrowArray`, `ArrowSchema`, `ArrowArrayStream`) and can
use nanoarrow for low-level R pointer/ownership helpers.

See:

- `docs/ARCHITECTURE.md`
- `docs/COPYING_FROM_DUCKTINYCC.md`
- `docs/NANOARROW.md`
