
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
outputs are accepted as constructed type objects such as `TYPE[]`,
`TYPE[N]`, `STRUCT(...)`, and `MAP(...)`. The type system also has
descriptors for `HUGEINT`, `UHUGEINT`, `UUID`, `INTERVAL`, `BIT`,
`DECIMAL(width, scale)`, `ENUM(levels)`, and `UNION(...)` for exact
R-side value validation. The default `mode = "row"` calls R once per
row; `mode = "arrow_lapply"` and `mode = "arrow_nanoarrow"` are reserved
for future batch UDF paths. Registration also supports `null_handling`,
`exception_handling`, and `side_effects` controls.

Direct R callbacks require single-thread DuckDB execution, so call
`rducks_enable(con, threads = "single")` or set `PRAGMA threads=1`
before registering R UDFs.

Rducks also provides explicit R value classes for planned exotic DuckDB
types: `rducks_uuid()`, `rducks_interval()`, `rducks_decimal()`,
`rducks_hugeint()`, `rducks_uhugeint()`, `rducks_bits()`,
`rducks_enum()`, and `rducks_union()`. These classes preserve exact
representation before native UDF marshalling for those types is enabled.
Constructed DuckDB type objects are formal S7-backed Rducks descriptors
with native structural checks via `rducks_is_type()`. Descriptors are
recursive, so lists, arrays, structs, maps, enums, decimals, and unions
can be nested through the constructors rather than quoted type strings.
`rducks_check_argument()` and `rducks_check_return()` can validate
ordinary R values against those descriptors before marshalling.

<details>
<summary>
Argument values passed to R callbacks
</summary>

The table is produced by the exported `rducks_argument_type_mapping()`
helper and reflects the currently implemented row-mode native
marshalling path. With `null_handling = "default"`, any top-level SQL
`NULL` input makes DuckDB return SQL `NULL` without calling the R
callback. The `SQL NULL in callback` column below applies when
`null_handling = "special"`. For composite inputs, top-level `NULL`
values are passed as R `NULL`; `NULL` elements in homogeneous scalar
lists/arrays are represented as typed `NA` values, while nested
composite `NULL` values are represented as R `NULL`.

| argument_type                | r_type    | r_value_passed_to_fun                                  | sql_null_in_callback  | copy_semantics         | notes                                                            |
|:-----------------------------|:----------|:-------------------------------------------------------|:----------------------|:-----------------------|:-----------------------------------------------------------------|
| BOOLEAN                      | logical   | logical(1)                                             | NA                    | boxed scalar           |                                                                  |
| TINYINT                      | integer   | integer(1)                                             | NA_integer\_          | boxed scalar           |                                                                  |
| UTINYINT                     | integer   | integer(1)                                             | NA_integer\_          | boxed scalar           |                                                                  |
| SMALLINT                     | integer   | integer(1)                                             | NA_integer\_          | boxed scalar           |                                                                  |
| USMALLINT                    | integer   | integer(1)                                             | NA_integer\_          | boxed scalar           |                                                                  |
| INTEGER                      | integer   | integer(1)                                             | NA_integer\_          | boxed scalar           |                                                                  |
| UINTEGER                     | numeric   | numeric(1)                                             | NA_real\_             | boxed scalar           | R double                                                         |
| BIGINT                       | numeric   | numeric(1)                                             | NA_real\_             | boxed scalar           | R double; exact only up to 2^53                                  |
| UBIGINT                      | numeric   | numeric(1)                                             | NA_real\_             | boxed scalar           | R double; exact only up to 2^53                                  |
| FLOAT                        | numeric   | numeric(1)                                             | NA_real\_             | boxed scalar           | widened to R double                                              |
| DOUBLE                       | numeric   | numeric(1)                                             | NA_real\_             | boxed scalar           |                                                                  |
| VARCHAR                      | character | character(1)                                           | NA_character\_        | string copied into R   | string copied into R                                             |
| BLOB                         | raw       | raw vector                                             | NULL                  | bytes copied into R    | bytes copied into R                                              |
| DATE                         | Date      | Date scalar                                            | NA_real\_ (unclassed) | boxed scalar           | days since 1970-01-01                                            |
| TIME                         | numeric   | numeric(1) seconds                                     | NA_real\_             | boxed scalar           | microseconds converted to seconds                                |
| TIMESTAMP                    | POSIXct   | POSIXct scalar                                         | NA_real\_ (unclassed) | boxed scalar           | microseconds converted to seconds                                |
| INTEGER\[\]                  | vector    | integer vector                                         | NULL                  | R vector allocation    | homogeneous scalar children use atomic vectors                   |
| INTEGER\[3\]                 | vector    | integer vector of length 3                             | NULL                  | R vector allocation    | fixed-size array; homogeneous scalar children use atomic vectors |
| STRUCT(a INTEGER, b VARCHAR) | list      | named list of fields                                   | NULL                  | recursive R allocation | recursive field mapping                                          |
| MAP(VARCHAR, INTEGER)        | list      | list(keys = character vector, values = integer vector) | NULL                  | recursive R allocation | keys and values use sequence mapping                             |

The exact descriptor/value-class families below exist for validation and
future native marshalling, but row-mode UDF registration currently
rejects them until the corresponding DuckDB vector read/write paths are
implemented.

| argument_type                        | R_value_class   | row_mode_callback_status |
|:-------------------------------------|:----------------|:-------------------------|
| `HUGEINT`                            | rducks_hugeint  | not implemented yet      |
| `UHUGEINT`                           | rducks_uhugeint | not implemented yet      |
| `UUID`                               | rducks_uuid     | not implemented yet      |
| `INTERVAL`                           | rducks_interval | not implemented yet      |
| `BIT`                                | rducks_bits     | not implemented yet      |
| `DECIMAL(10, 2)`                     | rducks_decimal  | not implemented yet      |
| `ENUM('red', 'blue')`                | rducks_enum     | not implemented yet      |
| `UNION(code INTEGER, label VARCHAR)` | rducks_union    | not implemented yet      |

</details>

``` r
nested_type <- STRUCT(
  payload = UNION(code = INTEGER, label = ENUM(c("red", "blue"))),
  amount = DECIMAL(10, 2),
  tags = LIST(ENUM(c("red", "blue")))
)

rducks_is_type(nested_type)
#> [1] TRUE
rducks_type_kind(nested_type)
#> [1] "struct"
rducks_type_sql(nested_type)
#> [1] "STRUCT(payload UNION(code INTEGER, label ENUM('red', 'blue')), amount DECIMAL(10, 2), tags ENUM('red', 'blue')[])"
rducks_type_child_names(nested_type)
#> [1] "payload" "amount"  "tags"
rducks_check_return(UNION(code = INTEGER, label = VARCHAR), rducks_union("label", "ok"))
rducks_check_return(ENUM(c("red", "blue")), rducks_enum("red", c("red", "blue")))
```

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
