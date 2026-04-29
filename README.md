
<!-- README.md is generated from README.Rmd. Please edit README.Rmd. -->

# Rducks

Rducks registers R scalar functions as DuckDB SQL functions. It ships as
an R package plus a DuckDB extension. Rtinycc compiles a small C wrapper
for each R function signature, and the loaded DuckDB extension registers
that wrapper on a DuckDB connection.

## Current scope

Implemented now:

- install-time build of `rducks.duckdb_extension`
- `rducks_enable()` to load the extension into a DuckDB connection
- `rducks_register()` for row-oriented scalar R UDFs
- scalar types: `bool`, `i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `i64`,
  `u64`, `f32`, `f64`, `varchar`, `blob`, `date`, `time`, and
  `timestamp`
- `null_handling`, `exception_handling`, and `side_effects` controls

Current constraint:

- direct R callbacks require single-thread DuckDB execution, so call
  `rducks_enable(con, threads = "single")` or set `PRAGMA threads=1`
  before registering R UDFs.

## Example

``` r
library(DBI)
library(duckdb)
library(Rducks)

con <- dbConnect(duckdb(config = list(allow_unsigned_extensions = "true")))
rducks_enable(con, threads = "single")

reg_plus_one <- rducks_register(
  con,
  name = "r_plus_one",
  fun = function(x) x + 1,
  args = "f64",
  returns = "f64"
)

dbGetQuery(con, "SELECT r_plus_one(41.0) AS x")
#>    x
#> 1 42
```

`u32`, `i64`, and `u64` are passed through R numeric (`double`),
matching the DuckDB R package’s default type mapping. Values beyond
`2^53` cannot be exactly represented as R doubles.

## NULL handling

By default, Rducks uses NULL-in/NULL-out handling: if any input is SQL
`NULL`, the R callback is not called and the SQL result is `NULL`.

Use `null_handling = "special"` to pass an R NA-like value to the R
function for SQL `NULL` inputs.

``` r
reg_null_special <- rducks_register(
  con,
  name = "r_null_special",
  fun = function(x) if (is.na(x)) 5L else x,
  args = "i32",
  returns = "i32",
  null_handling = "special"
)

dbGetQuery(con, "SELECT r_null_special(NULL::INTEGER) AS x")
#>   x
#> 1 5
```

## Exceptions and side effects

Set `exception_handling = "return_null"` to turn callback errors into
SQL `NULL`.

``` r
reg_error_null <- rducks_register(
  con,
  name = "r_error_null",
  fun = function(x) stop("boom"),
  args = "i32",
  returns = "i32",
  exception_handling = "return_null"
)

dbGetQuery(con, "SELECT r_error_null(1::INTEGER) AS x")
#>    x
#> 1 NA
```

Set `side_effects = TRUE` for callbacks with counters, randomness, I/O,
or mutation so DuckDB reruns the function for each row.

``` r
counter <- local({
  i <- 0L
  function() {
    i <<- i + 1L
    i
  }
})

reg_counter <- rducks_register(
  con,
  name = "r_counter",
  fun = counter,
  args = character(),
  returns = "i32",
  side_effects = TRUE
)

dbGetQuery(con, "SELECT r_counter() AS x FROM range(5)")
#>   x
#> 1 1
#> 2 2
#> 3 3
#> 4 4
#> 5 5
```

## Build notes

The package builds its DuckDB extension during installation using
`configure` or `configure.win`. The extension metadata footer is
appended by `tools/append_extension_metadata.R`.

DuckDB C API headers are refreshed explicitly with:

``` sh
Rscript tools/fetch_duckdb_headers.R --ref v1.2.0
```

See `docs/BUILD.md` for the extension build and metadata details.
