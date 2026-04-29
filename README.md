# Rducks

Rducks is an R package plus DuckDB extension for registering R functions as
DuckDB user-defined functions.

## Implemented now

- The package builds a small native DuckDB extension at install time.
- `rducks_enable()` loads that extension into a DuckDB connection.
- `rducks_register()` compiles an Rtinycc per-shape scalar wrapper and registers
  it through the loaded extension.
- The test suite executes the real path through `DBI::dbGetQuery()`.

## Current limits

- Implemented scalar types are `bool`, `i32`, `i64`, `f32`, `f64`, and
  `varchar`.
- Multi-threaded callback pumping is not implemented; direct callbacks require
  `PRAGMA threads=1` or `rducks_enable(con, threads = "single")`.
- Scalar wrappers are row-oriented; batch/Arrow wrappers are not wired in yet.
- Arrow/nanoarrow batch UDFs are not implemented yet.

## Real example

```r
library(DBI)
library(duckdb)
library(Rducks)

con <- dbConnect(duckdb(config = list(allow_unsigned_extensions = "true")))
rducks_enable(con, threads = "single")

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

Use `null_handling = "special"` when the R function should receive `NA` for
SQL `NULL` inputs instead of using NULL-in/NULL-out interception. Use
`side_effects = TRUE` for counters, randomness, I/O, or mutation so DuckDB does
not treat the function as pure.

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
