
<!-- README.md is generated from README.Rmd. Please edit README.Rmd. -->

# Rducks

Rducks registers R scalar functions as DuckDB SQL functions. It ships as
an R package plus a DuckDB extension. Rtinycc compiles a small C wrapper
for each R function signature, and the loaded DuckDB extension registers
that wrapper on a DuckDB connection.

## Current scope

Rducks currently builds `rducks.duckdb_extension` at install time, loads
it into DuckDB with `rducks_enable()`, and registers row-oriented scalar
R UDFs with `rducks_register()`. The implemented scalar input/output
type set is `BOOLEAN`, `TINYINT`, `UTINYINT`, `SMALLINT`, `USMALLINT`,
`INTEGER`, `UINTEGER`, `BIGINT`, `UBIGINT`, `FLOAT`, `DOUBLE`,
`VARCHAR`, `BLOB`, `DATE`, `TIME`, and `TIMESTAMP`. Composite inputs and
outputs are accepted as `TYPE[]`, `TYPE[N]`, `STRUCT(...)`, and
`MAP(...)`. The default `mode = "row"` calls R once per row;
`mode = "arrow_lapply"` and `mode = "arrow_nanoarrow"` are reserved for
future batch UDF paths. Registration also supports `null_handling`,
`exception_handling`, and `side_effects` controls.

Direct R callbacks require single-thread DuckDB execution, so call
`rducks_enable(con, threads = "single")` or set `PRAGMA threads=1`
before registering R UDFs.

<details>
<summary>
Argument values passed to R callbacks
</summary>

The table is produced by the exported `rducks_argument_type_mapping()`
helper. With `null_handling = "default"`, any top-level SQL `NULL` input
makes DuckDB return SQL `NULL` without calling the R callback. The
`SQL NULL in callback` column below applies when
`null_handling = "special"`. Nested SQL `NULL` values inside composite
inputs are represented as R `NULL`.

| argument_type                | r_value_passed_to_fun                                  | sql_null_in_callback  | notes                                                            |
|:-----------------------------|:-------------------------------------------------------|:----------------------|:-----------------------------------------------------------------|
| BOOLEAN                      | logical(1)                                             | NA                    |                                                                  |
| TINYINT                      | integer(1)                                             | NA_integer\_          |                                                                  |
| UTINYINT                     | integer(1)                                             | NA_integer\_          |                                                                  |
| SMALLINT                     | integer(1)                                             | NA_integer\_          |                                                                  |
| USMALLINT                    | integer(1)                                             | NA_integer\_          |                                                                  |
| INTEGER                      | integer(1)                                             | NA_integer\_          |                                                                  |
| UINTEGER                     | numeric(1)                                             | NA_real\_             | R double                                                         |
| BIGINT                       | numeric(1)                                             | NA_real\_             | R double; exact only up to 2^53                                  |
| UBIGINT                      | numeric(1)                                             | NA_real\_             | R double; exact only up to 2^53                                  |
| FLOAT                        | numeric(1)                                             | NA_real\_             | widened to R double                                              |
| DOUBLE                       | numeric(1)                                             | NA_real\_             |                                                                  |
| VARCHAR                      | character(1)                                           | NA_character\_        | string copied into R                                             |
| BLOB                         | raw vector                                             | NULL                  | bytes copied into R                                              |
| DATE                         | Date scalar                                            | NA_real\_ (unclassed) | days since 1970-01-01                                            |
| TIME                         | numeric(1) seconds                                     | NA_real\_             | microseconds converted to seconds                                |
| TIMESTAMP                    | POSIXct scalar                                         | NA_real\_ (unclassed) | microseconds converted to seconds                                |
| INTEGER\[\]                  | integer vector                                         | NULL                  | homogeneous scalar children use atomic vectors                   |
| INTEGER\[3\]                 | integer vector of length 3                             | NULL                  | fixed-size array; homogeneous scalar children use atomic vectors |
| STRUCT(a INTEGER, b VARCHAR) | named list of fields                                   | NULL                  | recursive field mapping                                          |
| MAP(VARCHAR, INTEGER)        | list(keys = character vector, values = integer vector) | NULL                  | keys and values use sequence mapping                             |

</details>

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
  args = DOUBLE,
  returns = DOUBLE,
  mode = "row"
)

dbGetQuery(con, "SELECT r_plus_one(41.0) AS x")
#>    x
#> 1 42
```

`rducks_register()` returns an `rducks_registration` object. Keep it if
you want to soft-unregister the UDF later with
`rducks_unregister(reg_plus_one)`.

The implemented mode is `mode = "row"`, which calls the R function once
per row. The names `mode = "arrow_lapply"` and
`mode = "arrow_nanoarrow"` are reserved for future batch UDF paths.

`u32`, `i64`, and `u64` are passed through R numeric (`double`),
matching the DuckDB R package’s default type mapping. Values beyond
`2^53` cannot be exactly represented as R doubles.

## Composite input examples

Homogeneous scalar lists and arrays are passed as atomic R vectors with
SQL `NULL` elements represented as typed `NA` values. Structs are passed
as named lists, and maps are passed as `list(keys = ..., values = ...)`.

``` r
reg_list_len <- rducks_register(
  con,
  name = "r_list_len",
  fun = function(x) length(x),
  args = INTEGER[],
  returns = INTEGER
)

reg_array_sum <- rducks_register(
  con,
  name = "r_array_sum",
  fun = function(x) sum(x),
  args = INTEGER[3],
  returns = INTEGER
)

reg_struct_sum <- rducks_register(
  con,
  name = "r_struct_sum",
  fun = function(x) x$a + x$b,
  args = STRUCT(a = INTEGER, b = INTEGER),
  returns = INTEGER
)

reg_map_sum <- rducks_register(
  con,
  name = "r_map_sum",
  fun = function(x) sum(x$values),
  args = MAP(VARCHAR, INTEGER),
  returns = INTEGER
)

reg_make_struct <- rducks_register(
  con,
  name = "r_make_struct",
  fun = function(x) list(a = x, b = x + 1L),
  args = INTEGER,
  returns = STRUCT(a = INTEGER, b = INTEGER)
)

reg_make_array <- rducks_register(
  con,
  name = "r_make_array",
  fun = function(x) c(x, x + 1L),
  args = INTEGER,
  returns = INTEGER[]
)

dbGetQuery(con, paste(
  "SELECT",
  "r_list_len([1,2,3]::INTEGER[]) AS list_len,",
  "r_array_sum([1,2,3]::INTEGER[3]) AS array_sum,",
  "r_struct_sum({'a': 20, 'b': 22}::STRUCT(a INTEGER, b INTEGER)) AS struct_sum,",
  "r_map_sum(map(['a','b'], [20,22])) AS map_sum,",
  "(r_make_struct(41::INTEGER)).b AS struct_return,",
  "list_sum(r_make_array(20::INTEGER)) AS array_return"
))
#>   list_len array_sum struct_sum map_sum struct_return array_return
#> 1        3         6         42      42            42           41
```

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
  args = INTEGER,
  returns = INTEGER,
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
  args = INTEGER,
  returns = INTEGER,
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
  returns = INTEGER,
  side_effects = TRUE
)

dbGetQuery(con, "SELECT r_counter() AS x FROM range(5)")
#>   x
#> 1 1
#> 2 2
#> 3 3
#> 4 4
#> 5 5

set.seed(1)
reg_rng <- rducks_register(
  con,
  name = "r_rng",
  fun = function() runif(1),
  args = character(),
  returns = DOUBLE,
  side_effects = TRUE
)

dbGetQuery(con, "SELECT r_rng() AS x FROM range(3)")
#>           x
#> 1 0.2655087
#> 2 0.3721239
#> 3 0.5728534
```

## Soft unregistering

DuckDB currently exposes extension scalar functions as internal catalog
entries, so `DROP FUNCTION` cannot remove them. `rducks_unregister()`
replaces the UDF overload with an inactive stub and releases Rducks’
R-side callback and compiled wrapper references.

``` r
reg_temp <- rducks_register(
  con,
  name = "r_temp",
  fun = function(x) x + 1L,
  args = INTEGER,
  returns = INTEGER
)

dbGetQuery(con, "SELECT r_temp(1::INTEGER) AS x")
#>   x
#> 1 2
rducks_unregister(reg_temp)
tryCatch(
  dbGetQuery(con, "SELECT r_temp(1::INTEGER) AS x"),
  error = function(e) conditionMessage(e)
)
#> [1] "Invalid Error: Invalid Input Error: Rducks UDF r_temp has been unregistered\nℹ Context: rapi_execute\nℹ Error type: INVALID"
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
