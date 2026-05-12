
<!-- README.md is generated from README.Rmd. Please edit README.Rmd. -->

# Rducks

[![R-CMD-check](https://github.com/sounkou-bioinfo/Rducks/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/sounkou-bioinfo/Rducks/actions/workflows/R-CMD-check.yaml)
[![R-universe](https://sounkou-bioinfo.r-universe.dev/badges/Rducks)](https://sounkou-bioinfo.r-universe.dev/Rducks)

Rducks registers R functions as DuckDB SQL functions using a DuckDB C
extension, including a small set of unstable DuckDB C extension API
functions. The extension records the DuckDB database instance handle at
initialization and keeps an extension-owned connection associated with
that runtime. UDF inputs and outputs move through explicit execution
plans:

- `arrow_r`: reference path using DuckDB Arrow C Data plus nanoarrow/R.
- `arrow_c`: native extension path for supported scalar and vectorized
  calls with direct DuckDB-vector materialization.
- `arrow_ipc`: process-isolated R execution using native NNG plus owned
  Arrow IPC request/result bytes. By default Rducks launches worker
  loops with mirai daemons and Rducks-generated NNG endpoint URLs;
  `ipc_transport` selects the generated transport and explicit
  `ipc_endpoints` can target externally managed workers.

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

reg_hello <- rducks_register(
  con,
  name = "r_hello",
  fun = function() "hello from R",
  args = NULL,
  returns = VARCHAR,
  mode = "scalar"
)

dbGetQuery(con, "SELECT r_hello() AS message")
#>        message
#> 1 hello from R

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

Use `args = NULL` for a zero-argument scalar UDF. `null_handling` only
affects SQL NULL inputs, so the default is appropriate for `r_hello()`.

`rducks_register()` returns an `rducks_registration` object that records
the connection, normalized signature, and registration options. You do
not need to keep this object for the UDF to keep working in DuckDB.
Registering the same SQL name/signature again replaces the callable
implementation in the shared DuckDB database catalog.

### Release and disconnect

`rducks_release(con)` detaches connection-local Rducks state such as the
current default plan and R-side runtime anchor. It is non-destructive:
it does not drop DuckDB catalog functions and does not release closures
still owned by native catalog metadata. Call it before
`DBI::dbDisconnect(con)` when you want deterministic R-side cleanup.
Rducks does not provide `rducks_unregister()`; registered catalog UDFs
and their preserved R closures are intentionally retained for the
database/runtime lifetime or until the same SQL name/signature is
replaced.

``` r
release_con <- dbConnect(duckdb(config = list(allow_unsigned_extensions = "true")))
rducks_enable(release_con, threads = "single")
rducks_release(release_con)
dbDisconnect(release_con, shutdown = TRUE)
```

### Arrow conversion setting

`rducks_enable()` sets DuckDB’s `arrow_lossless_conversion=true` setting
on the user connection, and the Rducks extension also sets it on its own
internal DuckDB connection. Rducks uses DuckDB’s Arrow C Data conversion
APIs for several execution plans, and this setting tells DuckDB to
preserve DuckDB-specific type identity in Arrow metadata when possible
instead of exporting only a more generic Arrow representation. This
matters for types such as `UUID`, `BIT`, `HUGEINT`/`UHUGEINT`,
`TIME WITH TIME ZONE`, and JSON aliases. It does not change stored
DuckDB values or SQL evaluation; it only affects DuckDB-to-Arrow
conversion used at the Rducks boundary.

## What you can register

Rducks installs a package-managed DuckDB extension, loads it into DuckDB
with `rducks_enable()`, and registers scalar or vectorized R UDFs with
`rducks_register()`.

Supported input/output descriptors are `BOOLEAN`, `TINYINT`, `UTINYINT`,
`SMALLINT`, `USMALLINT`, `INTEGER`, `UINTEGER`, `BIGINT`, `UBIGINT`,
`FLOAT`, `DOUBLE`, `VARCHAR`, `BLOB`, `DATE`, `TIME`, `TIMESTAMP`,
`HUGEINT`, `UHUGEINT`, `UUID`, `INTERVAL`, `BIT`,
`DECIMAL(width, scale)`, `ENUM(levels)`, and `UNION(...)`. Composite
inputs and outputs are accepted as constructed type objects such as
`TYPE[]`, `TYPE[N]`, `STRUCT(...)`, and `MAP(...)`, recursively over
supported child types.

Declared `ENUM(...)` descriptors are supported by all implemented
execution plans. On the native `arrow_ipc` NNG path, Rducks does not
depend on Arrow IPC dictionary transport for enums: declared enum levels
are registration metadata, and the IPC payload carries the underlying
DuckDB enum index storage as Arrow integer buffers.

Rducks also provides explicit R value classes for exact or
DuckDB-specific values: `rducks_bigint()`, `rducks_ubigint()`,
`rducks_uuid()`, `rducks_interval()`, `rducks_decimal()`,
`rducks_hugeint()`, `rducks_uhugeint()`, `rducks_bits()`,
`rducks_enum()`, and `rducks_union()`. Constructed DuckDB type objects
are formal S7-backed descriptors with structural validation via
`rducks_is_type()`.

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
bench::mark(
  scalar = dbGetQuery(con, "SELECT sum(r_plus_one(i::DOUBLE)) AS x FROM range(10000) AS t(i)"),
  vectorized = dbGetQuery(con, "SELECT sum(r_vec_plus_one(i::DOUBLE)) AS x FROM range(10000) AS t(i)"),
  iterations = 3,
  check = FALSE
)[, c("expression", "median", "itr/sec", "mem_alloc")]
#> # A tibble: 2 × 4
#>   expression   median `itr/sec` mem_alloc
#>   <bch:expr> <bch:tm>     <dbl> <bch:byt>
#> 1 scalar        293ms      3.43    1.97MB
#> 2 vectorized    232ms      4.31    2.34MB
```

## Execution mode semantics

The table below is produced by `rducks_mode_semantics()`.

| mode       | status      | call_granularity            | input_shape                                        | return_shape                                                          | null_semantics                                                                                                                                                 | length_semantics                                                   | error_semantics                                                                                                                                  | threading                                                                                                                                                                     | copy_semantics                                                                                                                                                                                                                                  | notes                                                                                                                                                        |
|:-----------|:------------|:----------------------------|:---------------------------------------------------|:----------------------------------------------------------------------|:---------------------------------------------------------------------------------------------------------------------------------------------------------------|:-------------------------------------------------------------------|:-------------------------------------------------------------------------------------------------------------------------------------------------|:------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|:------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|:-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| scalar     | implemented | one R call per row          | one scalar/composite R value per declared argument | one scalar/composite R value compatible with the declared return type | default NULL-in/NULL-out short-circuits; special mode passes scalar-shaped NA/NULL values                                                                      | one output value per R function call                               | R function errors become SQL NULL with exception_handling = ‘return_null’; type-checking and marshalling errors abort the query                  | R API work for arrow_r/arrow_c runs on the recorded main R thread; arrow_ipc + multiprocess_parallel evaluates scalar rows inside provider workers after Arrow IPC encoding   | DuckDB chunks are exported/imported through Arrow C Data for in-process plans; arrow_ipc plans copy chunk/task payloads into Arrow IPC raw bytes before process transport                                                                       | scalar arrow_ipc loops over rows inside the worker; in-process queuing is available for deadlock-safe same-process scheduling, not for parallel R evaluation |
| vectorized | implemented | one R call per DuckDB chunk | one R vector/list-column per declared argument     | one R vector/list of values compatible with the declared return type  | default mode evaluates only rows with no top-level SQL NULL inputs and scatters SQL NULLs back; special mode passes all rows with scalar-shaped NA/NULL values | return length must equal the number of evaluated rows in the chunk | R function errors make all evaluated rows SQL NULL with exception_handling = ‘return_null’; type-checking and marshalling errors abort the query | arrow_r and arrow_c vectorized work runs on the recorded main R thread; arrow_ipc + multiprocess_parallel offloads vectorized chunk work through the selected worker provider | arrow_r vectorized chunks are exported/imported through Arrow C Data; arrow_c vectorized materializes supported DuckDB vectors directly in native C; arrow_ipc plans copy chunk/task payloads into Arrow IPC raw bytes before process transport | batch/chunk call-shape used by arrow_r, direct arrow_c, and Arrow IPC worker-provider backends; zero-argument vectorized UDFs are not exposed yet            |

## Argument values passed to R functions

<details>
<summary>
Expand for argument values passed to R functions
</summary>

The table is produced by the exported `rducks_argument_type_mapping()`
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

| rducks_type                        | duckdb_sql                         | argument_kind | r_type       | r_value_passed_to_fun                                  | sql_null_in_function | copy_semantics                  | uses_r_double_for_integer | uses_r_double_for_float | precision_may_be_lost | notes                                                            |
|:-----------------------------------|:-----------------------------------|:--------------|:-------------|:-------------------------------------------------------|:---------------------|:--------------------------------|:--------------------------|:------------------------|:----------------------|:-----------------------------------------------------------------|
| i32                                | INTEGER                            | scalar        | integer      | integer(1)                                             | NA_integer\_         | boxed scalar                    | FALSE                     | FALSE                   | FALSE                 |                                                                  |
| f64                                | DOUBLE                             | scalar        | numeric      | numeric(1)                                             | NA_real\_            | boxed scalar                    | FALSE                     | FALSE                   | FALSE                 |                                                                  |
| list<i32>                          | INTEGER\[\]                        | list          | vector       | integer vector                                         | NULL                 | R vector allocation             | FALSE                     | FALSE                   | FALSE                 | homogeneous scalar children use atomic vectors                   |
| i64\[3\]                           | BIGINT\[3\]                        | array         | vector       | rducks_bigint vector of length 3                       | NULL                 | R vector allocation             | FALSE                     | FALSE                   | FALSE                 | fixed-size array; homogeneous scalar children use atomic vectors |
| struct\<a:uuid;b:decimal\<10;2\>\> | STRUCT(a UUID, b DECIMAL(10, 2))   | struct        | list         | named list of fields                                   | NULL                 | recursive R allocation          | FALSE                     | FALSE                   | FALSE                 | recursive field mapping                                          |
| map\<varchar;i32\>                 | MAP(VARCHAR, INTEGER)              | map           | list         | list(keys = character vector, values = integer vector) | NULL                 | recursive R allocation          | FALSE                     | FALSE                   | FALSE                 | keys and values use sequence mapping                             |
| enum\<red\|blue\>                  | ENUM(‘red’, ‘blue’)                | enum          | rducks_enum  | rducks_enum scalar                                     | NULL                 | boxed exact Rducks value object | FALSE                     | FALSE                   | FALSE                 | factor with enum levels                                          |
| union\<code:i32;label:varchar\>    | UNION(code INTEGER, label VARCHAR) | union         | rducks_union | rducks_union object                                    | NULL                 | boxed exact Rducks value object | FALSE                     | FALSE                   | FALSE                 | tagged value object                                              |

</details>

## NULL, NA, NaN, Inf, and value-class semantics

<details>
<summary>
Expand for NULL, NA, NaN, Inf, and value-class semantics
</summary>

The table below is produced by `rducks_value_semantics()`, the exported
schema that Rducks uses to document scalar-mode missing and non-finite
value behavior. Top-level R `NULL` returns map to SQL `NULL`. R `NA`
values map to SQL `NULL` when represented by the declared R type. `NaN`
and `Inf` are values only for `FLOAT` and `DOUBLE`; integer, date, time,
timestamp, exact, and exotic return paths reject them.

| rducks_type                     | duckdb_sql                         | kind    | r_type         | sql_null_input_default                                     | sql_null_input_special | sql_nan_inf_input                                            | r_null_return                                                  | r_na_return                                                                        | r_nan_return                       | r_inf_return                       | binary_ops                                                                    | error_semantics                                                                     | notes                                |
|:--------------------------------|:-----------------------------------|:--------|:---------------|:-----------------------------------------------------------|:-----------------------|:-------------------------------------------------------------|:---------------------------------------------------------------|:-----------------------------------------------------------------------------------|:-----------------------------------|:-----------------------------------|:------------------------------------------------------------------------------|:------------------------------------------------------------------------------------|:-------------------------------------|
| i32                             | INTEGER                            | scalar  | integer        | short-circuit to SQL NULL result; R function is not called | NA_integer\_           | not representable for this DuckDB type                       | SQL NULL                                                       | NA_integer\_ -\> SQL NULL                                                          | error                              | error                              | no Rducks-specific binary ops                                                 | NaN, Inf, fractional, and out-of-range return values error                          |                                      |
| f64                             | DOUBLE                             | scalar  | numeric        | short-circuit to SQL NULL result; R function is not called | NA_real\_              | DuckDB NaN/Inf pass through as R numeric values              | SQL NULL                                                       | NA_real\_ -\> SQL NULL                                                             | preserved as DuckDB NaN            | preserved as DuckDB +/-Inf         | ordinary R numeric semantics in the R function                                | NA is NULL; NaN and Inf are valid DOUBLE values                                     |                                      |
| i64                             | BIGINT                             | scalar  | rducks_bigint  | short-circuit to SQL NULL result; R function is not called | NULL                   | not representable for this DuckDB type                       | SQL NULL                                                       | rducks_bigint(NA) -\> SQL NULL                                                     | error                              | error                              | rducks_bigint +, -, comparisons; NA propagates; range errors remain errors    | non-integer strings, numeric NaN/Inf, and out-of-range values error                 | exact signed 64-bit integer string   |
| uuid                            | UUID                               | scalar  | rducks_uuid    | short-circuit to SQL NULL result; R function is not called | NULL                   | not representable for this DuckDB type                       | SQL NULL                                                       | rducks_uuid(NA) -\> SQL NULL                                                       | error                              | error                              | no Rducks-specific binary ops                                                 | NA UUID values are NULL; malformed UUID text errors                                 | exact Rducks value class             |
| decimal\<10;2\>                 | DECIMAL(10, 2)                     | decimal | rducks_decimal | short-circuit to SQL NULL result; R function is not called | NULL                   | not representable for DuckDB DECIMAL                         | SQL NULL for the top-level value; nested NULLs map recursively | rducks_decimal(NA, width, scale) -\> SQL NULL                                      | error                              | error                              | rducks_decimal +, -, comparisons; NA propagates; matching scales are required | NaN/Inf numeric inputs, scale/width mismatch, and DECIMAL arithmetic overflow error | exact fixed-point value class        |
| enum\<red\|blue\>               | ENUM(‘red’, ‘blue’)                | enum    | rducks_enum    | short-circuit to SQL NULL result; R function is not called | NULL                   | not representable for DuckDB ENUM                            | SQL NULL for the top-level value; nested NULLs map recursively | rducks_enum(NA, levels) -\> SQL NULL                                               | not applicable                     | not applicable                     | no Rducks-specific ENUM binary ops                                            | values outside the declared enum levels error                                       | factor with enum levels              |
| union\<code:i32;label:varchar\> | UNION(code INTEGER, label VARCHAR) | union   | rducks_union   | short-circuit to SQL NULL result; R function is not called | NULL                   | recursive: only FLOAT/DOUBLE union members can carry NaN/Inf | SQL NULL for the top-level value; nested NULLs map recursively | no missing tag; NA in the selected child follows that child semantics              | recursive selected-child semantics | recursive selected-child semantics | no Rducks-specific UNION binary ops                                           | missing, empty, or unknown tags and selected-child mismatches error                 | tagged value object                  |
| map\<varchar;i32\>              | MAP(VARCHAR, INTEGER)              | map     | list           | short-circuit to SQL NULL result; R function is not called | NULL                   | recursive: only FLOAT/DOUBLE children can carry NaN/Inf      | SQL NULL for the top-level value; nested NULLs map recursively | values recurse; scalar NA values become SQL NULL value entries; NULL/NA keys error | recursive child semantics          | recursive child semantics          | no descriptor-level Rducks binary ops; child value classes keep their own ops | keys/values length mismatch, NULL/NA keys, and child type mismatches error          | keys and values use sequence mapping |

</details>

## Composite input examples

Homogeneous scalar lists and arrays are passed as atomic R vectors with
SQL `NULL` elements represented as typed `NA` values. Structs are passed
as named lists, and maps are passed as `list(keys = ..., values = ...)`.
A `data.frame` return is not a table-valued UDF here; the scalar UDF
type equivalent is `STRUCT(...)`. In vectorized mode, a `STRUCT(...)`
return may be supplied as a `data.frame` with columns matching the
struct fields, yielding one struct-valued SQL result per row.

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

reg_make_map <- rducks_register(
  con,
  name = "r_make_map",
  fun = function(x) list(keys = c("a", "b"), values = c(x, x + 1L)),
  args = INTEGER,
  returns = MAP(VARCHAR, INTEGER)
)

dbGetQuery(con, "
  SELECT
    r_list_len([1,2,3]::INTEGER[]) AS list_len,
    r_array_sum([1,2,3]::INTEGER[3]) AS array_sum,
    r_struct_sum({'a': 20, 'b': 22}::STRUCT(a INTEGER, b INTEGER)) AS struct_sum,
    r_map_sum(map(['a','b'], [20,22])) AS map_sum,
    (r_make_struct(41::INTEGER)).b AS struct_return,
    list_sum(r_make_array(20::INTEGER)) AS array_return,
    map_extract_value(r_make_map(20::INTEGER), 'b') AS map_return
")
#>   list_len array_sum struct_sum map_sum struct_return array_return map_return
#> 1        3         6         42      42            42           41         21
```

## NULL handling

By default, Rducks uses NULL-in/NULL-out handling: if any input is SQL
`NULL`, the R function is not called and the SQL result is `NULL`.

Use `null_handling = "special"` to pass the type-specific missing value
shown in `rducks_argument_type_mapping()` to the R function for SQL
`NULL` inputs. For ordinary scalar types this is usually a typed `NA`;
for exact/exotic, binary, and composite inputs it is R `NULL`.

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

Set `exception_handling = "return_null"` to turn errors thrown by the
user R function into SQL `NULL`. Return type-checking and marshalling
errors still abort the query so type bugs are not hidden as NULLs.

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
#> 1 0.2655087
#> 2 0.3721239
#> 3 0.5728534
```

## Execution plans

Execution plans choose the default marshalling implementation and
concurrency contract for future registrations through a connection.
Registration remains semantic: name, function, mode, types, NULL
handling, exception handling, and side-effect flag. The plan active at
`rducks_register()` freezes the UDF’s native evaluator/marshalling
metadata; later plan changes do not retarget already-registered UDFs.

| Plan                                | Scalar      | Vectorized  | Notes                                                                                                                                                                                                                                                                  |
|-------------------------------------|-------------|-------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `arrow_r + serial`                  | implemented | implemented | reference implementation                                                                                                                                                                                                                                               |
| `arrow_r + inproc_concurrent`       | implemented | implemented | queued same-process callbacks; R API work stays on the recorded main R thread                                                                                                                                                                                          |
| `arrow_c + serial`                  | implemented | implemented | direct native evaluator tokens `RC`/`RCV`                                                                                                                                                                                                                              |
| `arrow_c + inproc_concurrent`       | implemented | implemented | queued same-process callbacks with direct `arrow_c` marshalling                                                                                                                                                                                                        |
| `arrow_ipc + multiprocess_parallel` | implemented | implemented | native NNG plus owned Arrow IPC bytes; mirai-launched local workers by default; `ipc_transport` generates `abstract` (Linux abstract IPC), `ipc` (NNG IPC), `unix` (POSIX Unix-domain alias), `tcp`, or `ws` endpoints; optional explicit `ipc_endpoints`; strict plan |

`arrow_r + serial` is the semantic reference. Other implemented plans
are tested against it and use exactly their selected marshalling path.
Use `rducks_explain_udf()` to inspect the plan and native counters for a
registered UDF.

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

`rducks_enable_inproc()` lets DuckDB worker threads enqueue same-process
R calls while the recorded main R thread drains the queue. This is for
safety and liveness, not automatic speed: R API work still runs on the
main thread.

``` r
rducks_register(
  con,
  name = "r_inproc_plus_one",
  fun = function(x) x + 1,
  args = DOUBLE,
  returns = DOUBLE
)
#> <rducks_registration>
#>   registered: yes
#>   name:       r_inproc_plus_one
#>   mode:       scalar
#>   plan:       arrow_r+serial
#>   signature:  r_inproc_plus_one(DOUBLE) -> DOUBLE

rducks_enable_inproc(con, threads = 4, external_threads = 1)
dbExecute(con, "CREATE TEMP TABLE inproc_input AS SELECT i::DOUBLE AS x FROM range(200000) AS t(i)")
#> [1] 2e+05
dbGetQuery(con, "SELECT sum(r_inproc_plus_one(x)) AS total FROM inproc_input")
#>         total
#> 1 20000100000
rducks_inproc_stats(con)[, c("submitted", "executed", "pending_max", "main_drain_batches")]
#>   submitted executed pending_max main_drain_batches
#> 1        38       38           1                 38
rducks_disable_inproc(con, threads = 1)
```

## Multiprocess Arrow IPC execution

`arrow_ipc + multiprocess_parallel` is the native NNG/Arrow IPC path:
DuckDB chunks become owned Arrow IPC bytes, native NNG sends them to R
worker loops, and Arrow IPC result bytes are imported back into DuckDB
output vectors. Local workers are mirai daemons running Rducks worker
loops; `ipc_endpoints` can point at externally managed NNG workers
instead.

Operationally:

- `ipc_workers` is the number of persistent R worker processes.
- `ipc_transport` chooses local mirai worker endpoints: `abstract`,
  `ipc`, `unix`, `tcp`, or `ws`.
- `ipc_timeout` is used for worker registration/control requests and for
  native NNG send/receive on each UDF’s client pool.
- Worker providers are reused by runtime, worker count, max-pending
  limit, and endpoint/transport choice. Registering another function
  with the same IPC provider key reuses the existing workers; changing
  that key starts another provider. Changing the default plan does not
  stop old providers.
- `rducks_release(con)` stops local providers when the last Rducks
  anchor for the DuckDB runtime is released. `rducks_nng_quiesce()` is
  lower-level: it only closes native client pools.

The example below registers the same vectorized R function three ways.
Keep `threads = 1` while registering; raise DuckDB `threads` for the IPC
query phase so chunks can fan out to the IPC workers.
`ripc_inflight_max` reports observed native IPC concurrency and is
scheduler-dependent.

``` r
chunk_plus_one <- function(x) {
  Sys.sleep(0.05) # visible chunk work for the comparison, not required by Rducks
  x + 1L
}

csv_dir <- file.path(tempdir(), paste0("rducks-ipc-csv-", Sys.getpid()))
dir.create(csv_dir, showWarnings = FALSE)
rows_per_file <- 4096L
parts <- 8L
for (part in seq_len(parts)) {
  values <- seq.int((part - 1L) * rows_per_file, part * rows_per_file - 1L)
  writeLines(c("i", as.character(values)), file.path(csv_dir, sprintf("part-%02d.csv", part)))
}
csv_glob <- file.path(csv_dir, "part-*.csv")

serial_plan <- rducks_execution_plan("arrow_r", "serial")
inproc_plan <- rducks_execution_plan("arrow_r", "inproc_concurrent")
ipc_workers <- 2L
ipc_plan <- rducks_execution_plan(
  "arrow_ipc", "multiprocess_parallel",
  ipc_transport = "tcp",
  ipc_workers = ipc_workers,
  ipc_timeout = 30
)

register_for_plan <- function(name, plan) {
  rducks_set_execution_plan(con, plan, threads = 1, external_threads = 1)
  invisible(rducks_register(
    con,
    name = name,
    fun = chunk_plus_one,
    args = INTEGER,
    returns = INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  ))
}

register_for_plan("r_cmp_serial", serial_plan)
register_for_plan("r_cmp_inproc", inproc_plan)
register_for_plan("r_cmp_ipc", ipc_plan)

run_comparison <- function(label, name, plan, threads) {
  rducks_set_execution_plan(con, plan, threads = threads, external_threads = 1)
  elapsed <- system.time({
    result <- dbGetQuery(con, sprintf(
      "SELECT sum(%s(i::INTEGER)) AS total FROM read_csv_auto(%s, header = true)",
      DBI::dbQuoteIdentifier(con, name),
      DBI::dbQuoteString(con, csv_glob)
    ))
  })[["elapsed"]]
  info <- rducks_explain_udf(con, name)
  data.frame(
    plan = label,
    threads = threads,
    total = result$total[[1]],
    elapsed_sec = round(unname(elapsed), 3),
    evaluator = info$evaluator[[1]],
    arrow_r_chunks = info$arrow_r_chunks[[1]],
    arrow_ipc_chunks = info$arrow_ipc_chunks[[1]],
    ripc_inflight_max = info$ripc_inflight_max[[1]],
    stringsAsFactors = FALSE
  )
}

comparison <- rbind(
  run_comparison("sequential arrow_r", "r_cmp_serial", serial_plan, threads = 1),
  run_comparison("in-process queue", "r_cmp_inproc", inproc_plan, threads = 1),
  run_comparison("2-process Arrow IPC", "r_cmp_ipc", ipc_plan, threads = ipc_workers)
)
comparison
#>                  plan threads     total elapsed_sec evaluator arrow_r_chunks
#> 1  sequential arrow_r       1 536887296       1.880         R             16
#> 2    in-process queue       1 536887296       1.841         R             16
#> 3 2-process Arrow IPC       2 536887296       1.065      RIPC              0
#>   arrow_ipc_chunks ripc_inflight_max
#> 1                0                 0
#> 2                0                 0
#> 3               16                 2

unlink(csv_dir, recursive = TRUE, force = TRUE)
rducks_set_execution_plan(con, serial_plan, threads = 1, external_threads = 1)
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

## DuckDB C extension ABI surface

The extension entrypoint receives the DuckDB database handle from
DuckDB’s extension access struct, stores it in a per-database runtime
record, and opens an extension-owned DuckDB connection for native
callback support. On extension reload, Rducks verifies that the active
connection has the SQL surface registered and re-registers it when
needed.

The unstable DuckDB C extension ABI entries are tracked by
`tools/used_duckdb_unstable_api.R` and documented in `docs/BUILD.md`.
The README intentionally does not source repository helper scripts while
rendering. The current output of
`source("tools/used_duckdb_unstable_api.R"); cat(rducks_used_duckdb_unstable_api_markdown("."))`
is:

| ABI group                                      | Functions used                                                                                                                                                                                                                                                                                       | Count |
|------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------:|
| `unstable_new_arrow_functions`                 | `duckdb_data_chunk_from_arrow`, `duckdb_data_chunk_to_arrow`, `duckdb_destroy_arrow_converted_schema`, `duckdb_schema_from_arrow`, `duckdb_to_arrow_schema`                                                                                                                                          |     5 |
| `unstable_new_error_data_functions`            | `duckdb_destroy_error_data`, `duckdb_error_data_has_error`, `duckdb_error_data_message`                                                                                                                                                                                                              |     3 |
| `unstable_new_open_connect_functions`          | `duckdb_client_context_get_connection_id`, `duckdb_connection_get_arrow_options`, `duckdb_destroy_arrow_options`, `duckdb_destroy_client_context`                                                                                                                                                    |     4 |
| `unstable_new_scalar_function_functions`       | `duckdb_scalar_function_bind_get_extra_info`, `duckdb_scalar_function_bind_set_error`, `duckdb_scalar_function_get_client_context`, `duckdb_scalar_function_set_bind`, `duckdb_scalar_function_set_bind_data`, `duckdb_scalar_function_set_bind_data_copy`                                           |     6 |
| `unstable_new_scalar_function_state_functions` | `duckdb_scalar_function_get_state`, `duckdb_scalar_function_init_get_bind_data`, `duckdb_scalar_function_init_get_client_context`, `duckdb_scalar_function_init_get_extra_info`, `duckdb_scalar_function_init_set_error`, `duckdb_scalar_function_init_set_state`, `duckdb_scalar_function_set_init` |     7 |
| `unstable_new_vector_functions`                | `duckdb_create_selection_vector`, `duckdb_destroy_selection_vector`, `duckdb_selection_vector_get_data_ptr`, `duckdb_vector_copy_sel`                                                                                                                                                                |     4 |
