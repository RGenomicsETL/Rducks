
<!-- README.md is generated from README.Rmd. Please edit README.Rmd. -->

# Rducks

Rducks registers R scalar functions as DuckDB SQL functions. It ships as
an R package plus a DuckDB extension. Rtinycc compiles a small C wrapper
for each R function signature, and the loaded DuckDB extension registers
that wrapper on a DuckDB connection.

## Current scope

Rducks currently builds `rducks.duckdb_extension` at install time, loads
it into DuckDB with `rducks_enable()`, and registers row-oriented scalar
R UDFs with `rducks_register()`. The row-mode input/output type set is
`BOOLEAN`, `TINYINT`, `UTINYINT`, `SMALLINT`, `USMALLINT`, `INTEGER`,
`UINTEGER`, `BIGINT`, `UBIGINT`, `FLOAT`, `DOUBLE`, `VARCHAR`, `BLOB`,
`DATE`, `TIME`, `TIMESTAMP`, `HUGEINT`, `UHUGEINT`, `UUID`, `INTERVAL`,
`BIT`, `DECIMAL(width, scale)`, `ENUM(levels)`, and `UNION(...)`.
Composite inputs and outputs are accepted as constructed type objects
such as `TYPE[]`, `TYPE[N]`, `STRUCT(...)`, and `MAP(...)`, recursively
over supported child types. The default `mode = "row"` calls R once per
row; `mode = "arrow_lapply"` and `mode = "arrow_nanoarrow"` are reserved
for future batch UDF paths. Registration also supports `null_handling`,
`exception_handling`, and `side_effects` controls.

Direct R callbacks require single-thread DuckDB execution, so call
`rducks_enable(con, threads = "single")` or set `PRAGMA threads=1`
before registering R UDFs.

Rducks also provides explicit R value classes for exact or
DuckDB-specific values: `rducks_bigint()`, `rducks_ubigint()`,
`rducks_uuid()`, `rducks_interval()`, `rducks_decimal()`,
`rducks_hugeint()`, `rducks_uhugeint()`, `rducks_bits()`,
`rducks_enum()`, and `rducks_union()`. These classes preserve exact
representation at the row-mode callback boundary. Constructed DuckDB
type objects are formal S7-backed Rducks descriptors with native
structural checks via `rducks_is_type()`. Descriptors are recursive, so
lists, arrays, structs, maps, enums, decimals, and unions can be nested
through the constructors rather than quoted type strings.
`rducks_check_argument()` and `rducks_check_return()` can validate
ordinary R values against those descriptors before marshalling.

## How it works

Rducks has two native boundaries: an R package that owns callback
lifetime and Rtinycc wrapper generation, and a loaded DuckDB extension
that owns SQL function registration and DuckDB vector access.

When you call `rducks_enable(con, threads = "single")`, Rducks loads the
bundled `rducks.duckdb_extension` into that DuckDB connection and
explicitly sets `PRAGMA threads=1`. Current row-mode R callbacks call
back into R directly, so single-thread DuckDB execution is required
until the future main-thread pump is implemented.

When you call `rducks_register()`, Rducks normalizes the declared DuckDB
type objects, checks that row-mode marshalling is available, preserves
the R callback, and generates a small C wrapper for that exact function
shape. Rtinycc compiles that wrapper in memory and returns a native
symbol pointer. The wrapper ABI is fixed: DuckDB-side native code passes
`void **` argument slots, NULL flags, an output slot, and an output NULL
flag; the generated wrapper converts those values to R objects, calls
the R function with `R_tryEvalSilent()`, and converts the result back to
the declared DuckDB type.

Registration then crosses back through SQL: Rducks calls the extension
function `rducks_register_scalar(...)`, passing the callback token,
compiled wrapper pointer, type descriptor tokens, and
NULL/exception/side-effect flags. The extension registers one DuckDB
scalar function implementation and stores the per-UDF metadata in DuckDB
`extra_info`. During query execution, that generic DuckDB callback reads
input vectors, constructs the row callback values, invokes the compiled
wrapper, and writes the result into the output vector.

The loaded-extension registration bridge was informed by
[DuckTinyCC](https://github.com/sounkou-bioinfo/DuckTinyCC), which
demonstrates DuckDB extension-side registration of compiler-backed C
UDFs. Rducks does not use DuckTinyCC as a backend: it uses
Rtinycc-generated R callback wrappers, Rducks type descriptors, and
R-specific SEXP/value-class marshalling.

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

| argument_type                        | r_type          | r_value_passed_to_fun                                  | sql_null_in_callback  | copy_semantics                  | notes                                                            |
|:-------------------------------------|:----------------|:-------------------------------------------------------|:----------------------|:--------------------------------|:-----------------------------------------------------------------|
| `BOOLEAN`                            | logical         | logical(1)                                             | NA                    | boxed scalar                    |                                                                  |
| `TINYINT`                            | integer         | integer(1)                                             | NA_integer\_          | boxed scalar                    |                                                                  |
| `UTINYINT`                           | integer         | integer(1)                                             | NA_integer\_          | boxed scalar                    |                                                                  |
| `SMALLINT`                           | integer         | integer(1)                                             | NA_integer\_          | boxed scalar                    |                                                                  |
| `USMALLINT`                          | integer         | integer(1)                                             | NA_integer\_          | boxed scalar                    |                                                                  |
| `INTEGER`                            | integer         | integer(1)                                             | NA_integer\_          | boxed scalar                    |                                                                  |
| `UINTEGER`                           | numeric         | numeric(1)                                             | NA_real\_             | boxed scalar                    | R double                                                         |
| `BIGINT`                             | rducks_bigint   | rducks_bigint scalar                                   | NULL                  | boxed exact Rducks value object | exact signed 64-bit integer string                               |
| `UBIGINT`                            | rducks_ubigint  | rducks_ubigint scalar                                  | NULL                  | boxed exact Rducks value object | exact unsigned 64-bit integer string                             |
| `FLOAT`                              | numeric         | numeric(1)                                             | NA_real\_             | boxed scalar                    | widened to R double                                              |
| `DOUBLE`                             | numeric         | numeric(1)                                             | NA_real\_             | boxed scalar                    |                                                                  |
| `VARCHAR`                            | character       | character(1)                                           | NA_character\_        | string copied into R            | string copied into R                                             |
| `BLOB`                               | raw             | raw vector                                             | NULL                  | bytes copied into R             | bytes copied into R                                              |
| `DATE`                               | Date            | Date scalar                                            | NA_real\_ (unclassed) | boxed scalar                    | days since 1970-01-01                                            |
| `TIME`                               | numeric         | numeric(1) seconds                                     | NA_real\_             | boxed scalar                    | microseconds converted to seconds                                |
| `TIMESTAMP`                          | POSIXct         | POSIXct scalar                                         | NA_real\_ (unclassed) | boxed scalar                    | microseconds converted to seconds                                |
| `HUGEINT`                            | rducks_hugeint  | rducks_hugeint                                         | NULL                  | boxed exact Rducks value object | exact Rducks value class                                         |
| `UHUGEINT`                           | rducks_uhugeint | rducks_uhugeint                                        | NULL                  | boxed exact Rducks value object | exact Rducks value class                                         |
| `UUID`                               | rducks_uuid     | rducks_uuid                                            | NULL                  | boxed exact Rducks value object | exact Rducks value class                                         |
| `INTERVAL`                           | rducks_interval | rducks_interval                                        | NULL                  | boxed exact Rducks value object | exact Rducks value class                                         |
| `BIT`                                | rducks_bits     | rducks_bits                                            | NULL                  | boxed exact Rducks value object | exact Rducks value class                                         |
| `INTEGER[]`                          | vector          | integer vector                                         | NULL                  | R vector allocation             | homogeneous scalar children use atomic vectors                   |
| `BIGINT[3]`                          | vector          | rducks_bigint vector of length 3                       | NULL                  | R vector allocation             | fixed-size array; homogeneous scalar children use atomic vectors |
| `STRUCT(a UUID, b DECIMAL(10, 2))`   | list            | named list of fields                                   | NULL                  | recursive R allocation          | recursive field mapping                                          |
| `MAP(VARCHAR, INTEGER)`              | list            | list(keys = character vector, values = integer vector) | NULL                  | recursive R allocation          | keys and values use sequence mapping                             |
| `DECIMAL(10, 2)`                     | rducks_decimal  | rducks_decimal scalar                                  | NULL                  | boxed exact Rducks value object | exact fixed-point value class                                    |
| `ENUM('red', 'blue')`                | rducks_enum     | rducks_enum scalar                                     | NULL                  | boxed exact Rducks value object | factor with enum levels                                          |
| `UNION(code INTEGER, label VARCHAR)` | rducks_union    | rducks_union object                                    | NULL                  | boxed exact Rducks value object | tagged value object                                              |

</details>
<details>
<summary>
NULL, NA, NaN, Inf, and value-class operation semantics
</summary>

The table below is produced by `rducks_value_semantics()`, the exported
schema that Rducks uses to document row-mode missing and non-finite
value behavior. Top-level R `NULL` returns map to SQL `NULL`. R `NA`
values map to SQL `NULL` when represented by the declared R type. `NaN`
and `Inf` are values only for `FLOAT` and `DOUBLE`; integer, date, time,
timestamp, exact, and exotic return paths reject them.

| duckdb_type                                | sql_null_special | r_na_return                                                             | r_nan_return                       | r_inf_return                       | binary_ops                                                                                      | error_semantics                                                                     |
|:-------------------------------------------|:-----------------|:------------------------------------------------------------------------|:-----------------------------------|:-----------------------------------|:------------------------------------------------------------------------------------------------|:------------------------------------------------------------------------------------|
| `INTEGER`                                  | NA_integer\_     | NA_integer\_ -\> SQL NULL                                               | error                              | error                              | no Rducks-specific binary ops                                                                   | NaN, Inf, fractional, and out-of-range return values error                          |
| `DOUBLE`                                   | NA_real\_        | NA_real\_ -\> SQL NULL                                                  | preserved as DuckDB NaN            | preserved as DuckDB +/-Inf         | ordinary R numeric semantics in the callback                                                    | NA is NULL; NaN and Inf are valid DOUBLE values                                     |
| `BIGINT`                                   | NULL             | rducks_bigint(NA) -\> SQL NULL                                          | error                              | error                              | rducks_bigint +, -, comparisons; NA propagates; range errors remain errors                      | non-integer strings, numeric NaN/Inf, and out-of-range values error                 |
| `UBIGINT`                                  | NULL             | rducks_ubigint(NA) -\> SQL NULL                                         | error                              | error                              | rducks_ubigint +, -, comparisons; NA propagates; unsigned underflow/range errors remain errors  | non-integer strings, numeric NaN/Inf, and out-of-range values error                 |
| `HUGEINT`                                  | NULL             | rducks_hugeint(NA) -\> SQL NULL                                         | error                              | error                              | rducks_hugeint +, -, comparisons; NA propagates; range errors remain errors                     | non-integer strings, numeric NaN/Inf, and out-of-range values error                 |
| `UHUGEINT`                                 | NULL             | rducks_uhugeint(NA) -\> SQL NULL                                        | error                              | error                              | rducks_uhugeint +, -, comparisons; NA propagates; unsigned underflow/range errors remain errors | non-integer strings, numeric NaN/Inf, and out-of-range values error                 |
| `UUID`                                     | NULL             | rducks_uuid(NA) -\> SQL NULL                                            | error                              | error                              | no Rducks-specific binary ops                                                                   | NA UUID values are NULL; malformed UUID text errors                                 |
| `INTERVAL`                                 | NULL             | any NA component in rducks_interval() -\> SQL NULL                      | error                              | error                              | rducks_interval + and -; NA components propagate; component overflow remains an error           | NaN/Inf components and months/days/micros outside DuckDB ranges error               |
| `BIT`                                      | NULL             | no NA bit payload; use R NULL for SQL NULL                              | error                              | error                              | rducks_bits &, \|, !, rducks_bits_xor(); NA bits are rejected                                   | BIT inputs must contain only 0/1 or TRUE/FALSE; NA bits error                       |
| `DECIMAL(10, 2)`                           | NULL             | rducks_decimal(NA, width, scale) -\> SQL NULL                           | error                              | error                              | rducks_decimal +, -, comparisons; NA propagates; matching scales are required                   | NaN/Inf numeric inputs, scale/width mismatch, and DECIMAL arithmetic overflow error |
| `ENUM('red', 'blue')`                      | NULL             | rducks_enum(NA, levels) -\> SQL NULL                                    | not applicable                     | not applicable                     | no Rducks-specific ENUM binary ops                                                              | values outside the declared enum levels error                                       |
| `UNION(code INTEGER, label VARCHAR)`       | NULL             | no missing tag; NA in the selected child follows that child semantics   | recursive selected-child semantics | recursive selected-child semantics | no Rducks-specific UNION binary ops                                                             | missing, empty, or unknown tags and selected-child mismatches error                 |
| `STRUCT(amount DECIMAL(10, 2), id BIGINT)` | NULL             | field values recurse; scalar field NA values become SQL NULL fields     | recursive child semantics          | recursive child semantics          | no descriptor-level Rducks binary ops; child value classes keep their own ops                   | missing fields and field type mismatches error                                      |
| `MAP(VARCHAR, INTEGER)`                    | NULL             | keys and values recurse; scalar NA values become SQL NULL child entries | recursive child semantics          | recursive child semantics          | no descriptor-level Rducks binary ops; child value classes keep their own ops                   | keys/values length mismatch and child type mismatches error                         |

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

`u32` is passed through R numeric (`double`). `BIGINT`, `UBIGINT`,
`HUGEINT`, and `UHUGEINT` use exact Rducks integer classes backed by
canonical decimal strings.

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
