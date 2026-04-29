# Rducks

Rducks is an experimental R package plus DuckDB extension bridge for registering
R functions as DuckDB user-defined functions.

The design target is:

```text
DuckDB extension loaded into a connection
  -> generic DuckDB scalar/table bridge
  -> Rtinycc-generated per-shape trampolines
  -> main-R-thread callback pump
  -> R callback result written back to DuckDB vectors
```

## Current status

This repository is an initial package scaffold. It includes:

- R package APIs for UDF specs, callback tokens, extension loading, and wrapper
  source generation
- a minimal native callback registry used by tests
- architecture notes for the DuckDB extension runtime
- a function catalog seed

The native DuckDB extension implementation is staged next.

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

## Example

```r
library(DBI)
library(duckdb)
library(Rducks)

con <- dbConnect(duckdb())
rducks_enable(con, threads = "single")

reg <- rducks_register(
  con,
  name = "r_plus_one",
  fun = function(x) x + 1,
  args = "f64",
  returns = "f64",
  mode = "compiled",
  compile = TRUE
)

cat(reg$source)
```
