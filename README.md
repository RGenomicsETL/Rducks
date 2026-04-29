# Rducks

Rducks is an R package plus DuckDB extension for registering R functions as
DuckDB user-defined functions.

## Implemented now

- The package builds a small native DuckDB extension at install time.
- `rducks_enable()` loads that extension into a DuckDB connection.
- `rducks_register()` registers one- or two-argument `DOUBLE -> DOUBLE` R scalar
  UDFs.
- The test suite executes the real path through `DBI::dbGetQuery()`.

## Current limits

- Only `f64` unary/binary scalar UDFs are implemented.
- Multi-threaded callback pumping is not implemented; `rducks_enable()` sets
  `PRAGMA threads=1` by default.
- Rtinycc-generated arbitrary-shape wrappers are not wired in yet.
- Arrow/nanoarrow batch UDFs are not implemented yet.

## Real example

```r
library(DBI)
library(duckdb)
library(Rducks)

con <- dbConnect(duckdb(config = list(allow_unsigned_extensions = "true")))
rducks_enable(con)

reg <- rducks_register(
  con,
  name = "r_plus_one",
  fun = function(x) x + 1,
  args = "f64",
  returns = "f64"
)

DBI::dbGetQuery(con, "SELECT r_plus_one(41.0) AS x")
#>    x
#> 1 42
```

## Intended next architecture

```text
DuckDB extension loaded into a connection
  -> generic DuckDB scalar/table bridge
  -> Rtinycc-generated per-shape trampolines
  -> main-R-thread callback pump
  -> R callback result written back to DuckDB vectors
```

## Why Rtinycc?

DuckDB scalar callbacks use one fixed C ABI, but R UDFs have arbitrary type
shapes. Rtinycc should be used as the dynamic shape compiler: Rducks can
generate a small C wrapper per UDF signature instead of interpreting every value
through a large runtime switch.

## Why nanoarrow?

Scalar UDFs do not require nanoarrow. Arrow-batch UDFs should use the in-process
Arrow C Data Interface (`ArrowArray`, `ArrowSchema`, `ArrowArrayStream`) and can
use nanoarrow for low-level R pointer/ownership helpers.

See:

- `docs/ARCHITECTURE.md`
- `docs/BUILD.md`
- `docs/NANOARROW.md`
