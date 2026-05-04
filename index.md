# Rducks

[![R-CMD-check](https://github.com/sounkou-bioinfo/Rducks/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/sounkou-bioinfo/Rducks/actions/workflows/R-CMD-check.yaml)
[![R-universe](https://sounkou-bioinfo.r-universe.dev/badges/Rducks)](https://sounkou-bioinfo.r-universe.dev/Rducks)

Rducks registers R functions as DuckDB SQL functions. It ships as an R
package plus a DuckDB extension. UDF inputs and outputs move through
explicit execution plans:

- `arrow_r`: reference path using DuckDB Arrow C Data plus nanoarrow/R.
- `arrow_c`: native extension path for supported scalar and vectorized
  calls.
- `arrow_ipc`: process-isolated path using Arrow IPC request/result
  payloads and a generic Future backend.

The user-facing UDF semantics are separate from the execution plan:
`mode = "scalar"` means one R call per logical row;
`mode = "vectorized"` means one R call per DuckDB chunk.

## Quick start

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
  mode = "scalar"
)

dbGetQuery(con, "SELECT r_plus_one(41.0) AS x")
#>    x
#> 1 42
```

[`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md)
returns an `rducks_registration` object that records the connection,
normalized signature, and registration options. You do not need to keep
this object for the UDF to keep working in DuckDB.

## Scalar and vectorized modes

Scalar mode calls the R function once per DuckDB row. Vectorized mode
calls the R function once per DuckDB chunk with one R vector/list-column
per declared argument.

``` r

reg_vec_plus_one <- rducks_register(
  con,
  name = "r_vec_plus_one",
  fun = function(x) x + 1,
  args = DOUBLE,
  returns = DOUBLE,
  mode = "vectorized",
  side_effects = TRUE
)

dbGetQuery(con, "SELECT sum(r_vec_plus_one(i::DOUBLE)) AS x FROM range(5) AS t(i)")
#>    x
#> 1 15
```

In vectorized mode, `null_handling = "default"` evaluates only rows with
no top-level SQL NULL inputs and scatters SQL NULLs back into the
result. `null_handling = "special"` passes all rows using the same
NA/NULL shapes as scalar mode. The return length must match the number
of evaluated rows. Vectorized mode currently requires at least one
declared argument.

A tiny benchmark with `bench` can show the call-shape difference for
simple R work. The result is illustrative rather than a performance
guarantee.

``` r

bench_n <- 10000L
bench_result <- bench::mark(
  scalar = DBI::dbGetQuery(
    con,
    sprintf("SELECT sum(r_plus_one(i::DOUBLE)) AS x FROM range(%d) AS t(i)", bench_n)
  ),
  vectorized = DBI::dbGetQuery(
    con,
    sprintf("SELECT sum(r_vec_plus_one(i::DOUBLE)) AS x FROM range(%d) AS t(i)", bench_n)
  ),
  iterations = 3,
  check = FALSE
)
bench_result[, c("expression", "median", "itr/sec", "mem_alloc")]
#> # A tibble: 2 × 4
#>   expression   median `itr/sec` mem_alloc
#>   <bch:expr> <bch:tm>     <dbl> <bch:byt>
#> 1 scalar        292ms      3.40    1.97MB
#> 2 vectorized    235ms      4.23    2.34MB
```

## Execution plans

Execution plans choose the marshalling implementation and concurrency
contract for a connection. Registration remains semantic: name,
function, mode, types, NULL handling, exception handling, and
side-effect flag.

| Plan | Scalar | Vectorized | Notes |
|----|----|----|----|
| `arrow_r + serial` | implemented | implemented | reference implementation |
| `arrow_r + inproc_concurrent` | implemented | implemented | queued same-process callbacks; R API work stays on the recorded R lane |
| `arrow_c + serial` | implemented | implemented | native evaluator token `RC` for scalar, `RCV` for vectorized |
| `arrow_c + inproc_concurrent` | implemented | implemented | queued same-process callbacks with `arrow_c` marshalling |
| `arrow_ipc + multiprocess_parallel` | implemented | implemented | Arrow IPC request/result payloads through the active Future backend; evaluator token `RIPC` |

`arrow_r + serial` is the semantic reference. Other implemented plans
are tested against it and do not silently fall back to another
marshalling path. Use
[`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md)
to inspect the plan and native counters for a registered UDF.

``` r

rducks_explain_udf(con, "r_vec_plus_one")[, c(
  "name", "mode", "plan_id", "native_marshalling",
  "evaluator", "arrow_r_chunks", "arrow_c_chunks", "arrow_ipc_chunks"
)]
#>             name       mode        plan_id native_marshalling evaluator
#> 1 r_vec_plus_one vectorized arrow_r+serial            arrow_r         R
#>   arrow_r_chunks arrow_c_chunks arrow_ipc_chunks
#> 1             21              0                0
```

## In-process queued execution

Register UDFs in the registration-safe configuration. Then call
[`rducks_enable_inproc()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable_inproc.md)
to switch query execution to the explicit in-process queue. This is a
liveness and scheduling feature for same-process callbacks; it still
serializes R API work on the recorded R lane.

DuckDB interprets `external_threads` as threads supplied by the caller
rather than DuckDB-created worker threads. For stress tests, prefer
settings such as `threads = 4, external_threads = 1`; do not set
`external_threads = threads` unless you intentionally want no
DuckDB-created worker pool.

``` r

reg_sleepy <- rducks_register(
  con,
  name = "r_sleepy_time",
  fun = function(x) {
    Sys.sleep(0.001)
    Sys.time()
  },
  args = DOUBLE,
  returns = TIMESTAMP,
  side_effects = TRUE
)

rducks_enable_inproc(con)

rducks_inproc_self_test(con, 3)
#> [1] 3
rducks_inproc_stats(con)
#>   submitted executed timeouts
#> 1         3        3        0

dbGetQuery(con, "SELECT r_sleepy_time(1.0) AS x")
#>                     x
#> 1 2026-05-04 22:55:10
rducks_inproc_stats(con)
#>   submitted executed timeouts
#> 1         4        4        0

rducks_disable_inproc(con, threads = 1)
```

## Multiprocess Arrow IPC execution

`arrow_ipc + multiprocess_parallel` uses Arrow IPC bytes for chunk tasks
and results. Scalar mode loops over rows inside the worker process;
vectorized mode calls the R function once per chunk inside the worker
process. Configure the Future backend before executing queries.

``` r

future::plan(future.mirai::mirai_multisession, workers = 2)

plan <- rducks_execution_plan(
  "arrow_ipc", "multiprocess_parallel",
  future_packages = "stats",
  future_timeout = 30
)
rducks_set_execution_plan(con, plan)

reg_ipc_plus_one <- rducks_register(
  con,
  name = "r_ipc_plus_one",
  fun = function(x) x + 1L,
  args = INTEGER,
  returns = INTEGER,
  mode = "vectorized",
  side_effects = TRUE
)

dbGetQuery(con, "SELECT sum(r_ipc_plus_one(i::INTEGER)) AS x FROM range(10000) AS t(i)")
#>          x
#> 1 50005000
rducks_explain_udf(con, "r_ipc_plus_one")[, c(
  "name", "mode", "plan_id", "evaluator",
  "arrow_ipc_chunks", "ripc_collect_batches", "ripc_collect_requests",
  "ripc_collect_max_batch"
)]
#>             name       mode                         plan_id evaluator
#> 1 r_ipc_plus_one vectorized arrow_ipc+multiprocess_parallel      RIPC
#>   arrow_ipc_chunks ripc_collect_batches ripc_collect_requests
#> 1                5                    5                     5
#>   ripc_collect_max_batch
#> 1                      1
```

This is the real `arrow_ipc + multiprocess_parallel` UDF implementation.
The native extension submits Arrow IPC chunk work through the
Future-backed RIPC path and imports the returned Arrow IPC result into
DuckDB. The `ripc_collect_max_batch` counter reports how many submitted
RIPC chunk requests the native queue collected together in one batch for
this query.

## Current scope

Rducks currently builds `rducks.duckdb_extension` at install time, loads
it into DuckDB with
[`rducks_enable()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable.md),
and registers scalar or vectorized R UDFs with
[`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md).

The input/output type set is `BOOLEAN`, `TINYINT`, `UTINYINT`,
`SMALLINT`, `USMALLINT`, `INTEGER`, `UINTEGER`, `BIGINT`, `UBIGINT`,
`FLOAT`, `DOUBLE`, `VARCHAR`, `BLOB`, `DATE`, `TIME`, `TIMESTAMP`,
`HUGEINT`, `UHUGEINT`, `UUID`, `INTERVAL`, `BIT`,
`DECIMAL(width, scale)`, `ENUM(levels)`, and `UNION(...)`. Composite
inputs and outputs are accepted as constructed type objects such as
`TYPE[]`, `TYPE[N]`, `STRUCT(...)`, and `MAP(...)`, recursively over
supported child types.

Enum types are supported by all implemented execution plans. For
`arrow_ipc`, Rducks does not rely on general Arrow dictionary IPC
because the nanoarrow C IPC writer used by this path does not yet encode
dictionary arrays. Instead, enum payloads use the declared Rducks type
descriptor as the dictionary sidecar and serialize the DuckDB enum
storage indices as ordinary Arrow integer arrays. This is an explicit
Rducks wire convention for declared `ENUM(...)` types, not general
support for arbitrary Arrow dictionary arrays. A future same-host
payload mode such as `mori` may optimize this path further.

Rducks also provides explicit R value classes for exact or
DuckDB-specific values:
[`rducks_bigint()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_bigint.md),
[`rducks_ubigint()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_ubigint.md),
[`rducks_uuid()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_uuid.md),
[`rducks_interval()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_interval.md),
[`rducks_decimal()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_decimal.md),
[`rducks_hugeint()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_hugeint.md),
[`rducks_uhugeint()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_uhugeint.md),
[`rducks_bits()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_bits.md),
[`rducks_enum()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enum.md),
and
[`rducks_union()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_union.md).
Constructed DuckDB type objects are formal S7-backed descriptors with
structural validation via
[`rducks_is_type()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_type_objects.md).

## Execution mode semantics

The table below is produced by
[`rducks_mode_semantics()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_mode_semantics.md).

| mode | status | call_granularity | input_shape | return_shape | length_semantics | threading | copy_semantics |
|:---|:---|:---|:---|:---|:---|:---|:---|
| `scalar` | implemented | one R call per row | one scalar/composite R value per declared argument | one scalar/composite R value compatible with the declared return type | one output value per R function call | R API work for arrow_r/arrow_c runs on the recorded main R thread; arrow_ipc + multiprocess_parallel evaluates scalar rows inside Future workers after Arrow IPC encoding | DuckDB chunks are exported/imported through Arrow C Data for in-process plans; arrow_ipc plans copy chunk/task payloads into Arrow IPC raw bytes before process transport |
| `vectorized` | implemented | one R call per DuckDB chunk | one R vector/list-column per declared argument | one R vector/list of values compatible with the declared return type | return length must equal the number of evaluated rows in the chunk | same execution-plan threading rules as scalar mode for arrow_r/arrow_c; arrow_ipc + multiprocess_parallel offloads vectorized chunk work through the current future backend | DuckDB chunks are exported/imported through Arrow C Data; arrow_ipc plans copy chunk/task payloads into Arrow IPC raw bytes before process transport |

## Type descriptors

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

### Argument values passed to R functions

Expand for argument values passed to R functions

The table is produced by the exported
[`rducks_argument_type_mapping()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_argument_type_mapping.md)
helper and reflects the currently implemented nanoarrow scalar
marshalling path. With `null_handling = "default"`, any top-level SQL
`NULL` input makes DuckDB return SQL `NULL` without calling the R
function. The `SQL NULL in function` column below applies when
`null_handling = "special"`. It is type-specific: ordinary R scalar
types receive typed `NA` values, while exact/exotic value classes,
binary values, and top-level composite values receive R `NULL`. Within
homogeneous scalar lists/arrays, SQL `NULL` elements are represented as
typed `NA` values where the child type has an R `NA` representation;
nested composite `NULL` values are represented as R `NULL`.

| argument_type | r_type | r_value_passed_to_fun | sql_null_in_function | copy_semantics | notes |
|:---|:---|:---|:---|:---|:---|
| `BOOLEAN` | logical | logical(1) | NA | boxed scalar |  |
| `TINYINT` | integer | integer(1) | NA_integer\_ | boxed scalar |  |
| `UTINYINT` | integer | integer(1) | NA_integer\_ | boxed scalar |  |
| `SMALLINT` | integer | integer(1) | NA_integer\_ | boxed scalar |  |
| `USMALLINT` | integer | integer(1) | NA_integer\_ | boxed scalar |  |
| `INTEGER` | integer | integer(1) | NA_integer\_ | boxed scalar |  |
| `UINTEGER` | numeric | numeric(1) | NA_real\_ | boxed scalar | R double |
| `BIGINT` | rducks_bigint | rducks_bigint scalar | NULL | boxed exact Rducks value object | exact signed 64-bit integer string |
| `UBIGINT` | rducks_ubigint | rducks_ubigint scalar | NULL | boxed exact Rducks value object | exact unsigned 64-bit integer string |
| `FLOAT` | numeric | numeric(1) | NA_real\_ | boxed scalar | widened to R double |
| `DOUBLE` | numeric | numeric(1) | NA_real\_ | boxed scalar |  |
| `VARCHAR` | character | character(1) | NA_character\_ | string copied into R | string copied into R |
| `BLOB` | raw | raw vector | NULL | bytes copied into R | bytes copied into R |
| `DATE` | Date | Date scalar | Date NA | boxed scalar | days since 1970-01-01 |
| `TIME` | numeric | numeric(1) seconds | NA_real\_ | boxed scalar | microseconds converted to seconds |
| `TIMESTAMP` | POSIXct | POSIXct scalar | POSIXct NA | boxed scalar | microseconds converted to seconds |
| `HUGEINT` | rducks_hugeint | rducks_hugeint | NULL | boxed exact Rducks value object | exact Rducks value class |
| `UHUGEINT` | rducks_uhugeint | rducks_uhugeint | NULL | boxed exact Rducks value object | exact Rducks value class |
| `UUID` | rducks_uuid | rducks_uuid | NULL | boxed exact Rducks value object | exact Rducks value class |
| `INTERVAL` | rducks_interval | rducks_interval | NULL | boxed exact Rducks value object | exact Rducks value class |
| `BIT` | rducks_bits | rducks_bits | NULL | boxed exact Rducks value object | exact Rducks value class |
| `INTEGER[]` | vector | integer vector | NULL | R vector allocation | homogeneous scalar children use atomic vectors |
| `BIGINT[3]` | vector | rducks_bigint vector of length 3 | NULL | R vector allocation | fixed-size array; homogeneous scalar children use atomic vectors |
| `STRUCT(a UUID, b DECIMAL(10, 2))` | list | named list of fields | NULL | recursive R allocation | recursive field mapping |
| `MAP(VARCHAR, INTEGER)` | list | list(keys = character vector, values = integer vector) | NULL | recursive R allocation | keys and values use sequence mapping |
| `DECIMAL(10, 2)` | rducks_decimal | rducks_decimal scalar | NULL | boxed exact Rducks value object | exact fixed-point value class |
| `ENUM('red', 'blue')` | rducks_enum | rducks_enum scalar | NULL | boxed exact Rducks value object | factor with enum levels |
| `UNION(code INTEGER, label VARCHAR)` | rducks_union | rducks_union object | NULL | boxed exact Rducks value object | tagged value object |

### NULL, NA, NaN, Inf, and value-class semantics

Expand for NULL, NA, NaN, Inf, and value-class semantics

The table below is produced by
[`rducks_value_semantics()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_value_semantics.md),
the exported schema that Rducks uses to document scalar-mode missing and
non-finite value behavior. Top-level R `NULL` returns map to SQL `NULL`.
R `NA` values map to SQL `NULL` when represented by the declared R type.
`NaN` and `Inf` are values only for `FLOAT` and `DOUBLE`; integer, date,
time, timestamp, exact, and exotic return paths reject them.

| duckdb_type | sql_null_special | r_na_return | r_nan_return | r_inf_return | binary_ops | error_semantics |
|:---|:---|:---|:---|:---|:---|:---|
| `INTEGER` | NA_integer\_ | NA_integer\_ -\> SQL NULL | error | error | no Rducks-specific binary ops | NaN, Inf, fractional, and out-of-range return values error |
| `DOUBLE` | NA_real\_ | NA_real\_ -\> SQL NULL | preserved as DuckDB NaN | preserved as DuckDB +/-Inf | ordinary R numeric semantics in the R function | NA is NULL; NaN and Inf are valid DOUBLE values |
| `BIGINT` | NULL | rducks_bigint(NA) -\> SQL NULL | error | error | rducks_bigint +, -, comparisons; NA propagates; range errors remain errors | non-integer strings, numeric NaN/Inf, and out-of-range values error |
| `UBIGINT` | NULL | rducks_ubigint(NA) -\> SQL NULL | error | error | rducks_ubigint +, -, comparisons; NA propagates; unsigned underflow/range errors remain errors | non-integer strings, numeric NaN/Inf, and out-of-range values error |
| `HUGEINT` | NULL | rducks_hugeint(NA) -\> SQL NULL | error | error | rducks_hugeint +, -, comparisons; NA propagates; range errors remain errors | non-integer strings, numeric NaN/Inf, and out-of-range values error |
| `UHUGEINT` | NULL | rducks_uhugeint(NA) -\> SQL NULL | error | error | rducks_uhugeint +, -, comparisons; NA propagates; unsigned underflow/range errors remain errors | non-integer strings, numeric NaN/Inf, and out-of-range values error |
| `UUID` | NULL | rducks_uuid(NA) -\> SQL NULL | error | error | no Rducks-specific binary ops | NA UUID values are NULL; malformed UUID text errors |
| `INTERVAL` | NULL | any NA component in rducks_interval() -\> SQL NULL | error | error | rducks_interval + and -; NA components propagate; component overflow remains an error | NaN/Inf components and months/days/micros outside DuckDB ranges error |
| `BIT` | NULL | no NA bit payload; use R NULL for SQL NULL | error | error | rducks_bits &, \|, !, rducks_bits_xor(); NA bits are rejected | BIT inputs must contain only 0/1 or TRUE/FALSE; NA bits error |
| `DECIMAL(10, 2)` | NULL | rducks_decimal(NA, width, scale) -\> SQL NULL | error | error | rducks_decimal +, -, comparisons; NA propagates; matching scales are required | NaN/Inf numeric inputs, scale/width mismatch, and DECIMAL arithmetic overflow error |
| `ENUM('red', 'blue')` | NULL | rducks_enum(NA, levels) -\> SQL NULL | not applicable | not applicable | no Rducks-specific ENUM binary ops | values outside the declared enum levels error |
| `UNION(code INTEGER, label VARCHAR)` | NULL | no missing tag; NA in the selected child follows that child semantics | recursive selected-child semantics | recursive selected-child semantics | no Rducks-specific UNION binary ops | missing, empty, or unknown tags and selected-child mismatches error |
| `STRUCT(amount DECIMAL(10, 2), id BIGINT)` | NULL | field values recurse; scalar field NA values become SQL NULL fields | recursive child semantics | recursive child semantics | no descriptor-level Rducks binary ops; child value classes keep their own ops | missing fields and field type mismatches error |
| `MAP(VARCHAR, INTEGER)` | NULL | values recurse; scalar NA values become SQL NULL value entries; NULL/NA keys error | recursive child semantics | recursive child semantics | no descriptor-level Rducks binary ops; child value classes keep their own ops | keys/values length mismatch, NULL/NA keys, and child type mismatches error |

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
`NULL`, the R function is not called and the SQL result is `NULL`.

Use `null_handling = "special"` to pass the type-specific missing value
shown in
[`rducks_argument_type_mapping()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_argument_type_mapping.md)
to the R function for SQL `NULL` inputs. For ordinary scalar types this
is usually a typed `NA`; for exact/exotic, binary, and composite inputs
it is R `NULL`.

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

Set `exception_handling = "return_null"` to turn R errors into SQL
`NULL`.

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

Set `side_effects = TRUE` for functions with counters, randomness, I/O,
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
#> 1 0.6775328
#> 2 0.4273457
#> 3 0.9103805
```

## Build notes

The package builds its DuckDB extension during installation using
`configure` or `configure.win`. The extension metadata footer is
appended by `tools/append_extension_metadata.R`.

DuckDB C API headers are refreshed explicitly with:

``` sh
Rscript tools/fetch_duckdb_headers.R --ref v1.5.2
```

The DuckDB Arrow C Data path requires DuckDB’s unstable C extension API,
so the extension metadata uses `C_STRUCT_UNSTABLE` and must match the
bundled DuckDB header/runtime version. See `docs/BUILD.md` for the
extension build and metadata details.
