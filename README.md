
<!-- README.md is generated from README.Rmd. Please edit README.Rmd. -->

# Rducks

[![R-CMD-check](https://github.com/sounkou-bioinfo/Rducks/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/sounkou-bioinfo/Rducks/actions/workflows/R-CMD-check.yaml)
[![R-universe](https://sounkou-bioinfo.r-universe.dev/badges/Rducks)](https://sounkou-bioinfo.r-universe.dev/Rducks)

Rducks registers R functions as DuckDB SQL functions. It ships as an R
package plus a DuckDB extension. The loaded DuckDB extension registers R
functions on a DuckDB connection and executes scalar/vectorized chunks
through explicit `arrow_r`, `arrow_c`, or `arrow_ipc` marshalling plans.
In-process plans use DuckDB Arrow C Data plus nanoarrow; the
multiprocess plan uses Arrow IPC request/result payloads through a
generic Future provider.

## How it works

Rducks has two native boundaries: an R package that owns registration
ergonomics, and a loaded DuckDB extension that owns SQL function
registration, DuckDB chunk access, R function preservation while DuckDB
owns the UDF, and current scalar/vectorized R function execution.

When you call `rducks_enable()`, Rducks loads the bundled
`rducks.duckdb_extension` into that DuckDB connection, enables DuckDB’s
lossless Arrow conversion, and records the current R thread as the only
lane allowed to call R. During extension initialization, DuckDB passes
the extension entrypoint a `duckdb_connection` plus extension
metadata/access handles. Rducks obtains the underlying `duckdb_database`
via `access->get_database(info)`, keys native runtime state by that
database handle, and opens an extension-owned `duckdb_connection` for
registration work that must be owned by the extension rather than by R
wrapper internals. With `threads = "single"`, `rducks_enable()` also
sets `external_threads=1` and `PRAGMA threads=1`; use that
registration-safe setting while adding UDFs.

When you call `rducks_register()`, Rducks normalizes the declared DuckDB
type objects, checks that Arrow C Data marshalling is available, and
preserves the R function. Registration then crosses back through SQL:
Rducks calls the extension function `rducks_register_scalar(...)`,
passing the R function reference, type descriptor tokens, and
NULL/exception/side-effect flags. The extension registers one generic
DuckDB scalar function implementation and stores the per-UDF metadata in
DuckDB `extra_info`.

Query execution is described by a connection-level execution plan with
two orthogonal pieces:

- marshalling: `arrow_r` is the Arrow C Data plus nanoarrow/R reference
  path; `arrow_c` is the native extension path for scalar row calls and
  vectorized chunk calls; `arrow_ipc` uses Arrow IPC bytes as the
  explicit process transport payload.
- concurrency: `serial` evaluates one chunk at a time in-process;
  `inproc_concurrent` allows concurrent DuckDB callbacks but still runs
  all R API work on the recorded R execution lane;
  `multiprocess_parallel` uses the current generic Future backend for
  process-isolated chunk work.

`rducks_enable()` selects the reference `arrow_r + serial` plan.
`rducks_enable_inproc()` is a compatibility helper that switches the
concurrency part to `inproc_concurrent` while preserving the current
marshalling choice. No R API work runs on DuckDB worker threads, and the
in-process queue has timeout/error paths rather than a hidden pump.

For scalar mode, `arrow_r` maps to the R/nanoarrow row evaluator,
`arrow_c` maps to the native C row-loop evaluator, and `arrow_ipc` loops
over logical rows inside the worker process. For vectorized mode,
`arrow_r`, `arrow_c`, and `arrow_ipc` call the R function once per
chunk. The `arrow_c` vectorized path uses native evaluator token `RCV`;
`arrow_ipc` uses evaluator token `RIPC`. Per-UDF counters report the
requested path (`arrow_c_chunks` or `arrow_ipc_chunks`), not
`arrow_r_chunks`, so tests can detect accidental fallback.

## Getting started

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

`rducks_register()` returns an `rducks_registration` object that records
the connection, normalized signature, and registration options. You do
not need to keep this object for the UDF to keep working in DuckDB.

Rducks implements two R call shapes. `mode = "scalar"` calls the R
function once per DuckDB row. `mode = "vectorized"` calls the R function
once per DuckDB chunk with one R vector/list-column per declared
argument. Both adapters are nanoarrow-backed over DuckDB Arrow C Data:
DuckDB calls the native scalar UDF on real chunks, and Rducks adapts
those chunks to the requested R call shape.

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
of evaluated rows. Vectorized mode is supported by both `arrow_r` and
`arrow_c` execution plans and requires at least one declared argument.

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
#> 1 scalar        295ms      3.36    1.97MB
#> 2 vectorized    240ms      4.16    2.34MB
```

### In-process queued execution

Register UDFs in the registration-safe configuration. Then call
`rducks_enable_inproc()` to switch query execution to the explicit
in-process queue. Pass `threads`/`external_threads` there if you want to
raise DuckDB’s thread settings for queued execution. DuckDB interprets
`external_threads` as threads supplied by the caller rather than
DuckDB-created worker threads, so use values such as
`threads = 4, external_threads = 1` for stress tests instead of
`external_threads = threads`. R calls are still serialized on the
recorded main R thread, but queued worker requests have timeout/error
paths rather than deadlocking indefinitely. The helper preserves the
current marshalling choice: both `arrow_r + inproc_concurrent` and
`arrow_c + inproc_concurrent` support scalar and vectorized UDFs. R
callbacks are still serialized on the recorded R lane.

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
#> 1 2026-05-04 21:13:13
rducks_inproc_stats(con)
#>   submitted executed timeouts
#> 1         4        4        0

rducks_disable_inproc(con, threads = 1)
```

### Evaluation implementations

`mode = "scalar"` has three evaluator implementations selected by the
active connection execution plan:

- `arrow_r` uses the original R/nanoarrow row-loop adapter.
- `arrow_c` uses a native C row-loop adapter. It evaluates the same R
  function once per logical row, so ordinary R semantics including S3/S7
  dispatch, RNG, lexical scope, and side effects still come from R’s
  evaluator.
- `arrow_ipc` encodes each chunk as Arrow IPC and loops over logical
  rows inside a Future worker process.

`mode = "vectorized"` also has three plan implementations:

- `arrow_r` uses the reference R/nanoarrow chunk adapter.
- `arrow_c` uses native extension dispatch with evaluator token `RCV`
  and the vectorized chunk adapter. This is a named `arrow_c` path with
  explicit counters, not a hidden fallback to the public `arrow_r`
  evaluator.
- `arrow_ipc` encodes each chunk as Arrow IPC and calls the R function
  once per chunk inside a Future worker process.

All scalar evaluators preserve the same scalar-mode contract:
`null_handling = "default"` skips calls for top-level SQL NULL inputs,
`null_handling = "special"` calls the R function with the documented R
missing-value shape, and `side_effects = TRUE` marks the DuckDB function
volatile. Rducks includes `arrow_r`-vs-`arrow_c` conformance tests for
scalar, exact, composite, enum, union, NULL, error, RNG, and vectorized
chunk behavior. The generated conformance matrix can also include
`arrow_ipc + multiprocess_parallel` cases with
`RDUCKS_MATRIX_INCLUDE_IPC=true`.

The `arrow_c` implementation uses borrowed DuckDB input vectors only
during the native UDF callback. Per-row R arguments are fresh R objects,
so a user function may retain them without observing later row mutation.
Direct DuckDB output-buffer writes are used where implemented; strings
and raw values are assigned through DuckDB’s vector assignment API,
which copies into DuckDB-owned storage. Rducks does not retain pointers
into DuckDB-owned chunks after the callback returns.

The current `arrow_ipc + multiprocess_parallel` UDF callback
implementation is real and uses Arrow IPC request/result payloads
through Future workers. It is not the maximally parallel multiprocess
architecture because DuckDB scalar UDF callbacks are synchronous: each
callback owns only its current input chunk and output vector, and that
output vector must be filled before the callback returns. For
throughput, the intended multiprocess path is an owned prechunk
pipeline: split an input source into owned Arrow IPC chunk tasks, submit
a window of tasks to workers, collect by sequence, and then expose the
result. The development benchmark `tools/benchmark_owned_ipc_pipeline.R`
exercises that shape and shows why it is the preferred hot path.
Same-host shared-memory payloads such as `mori` can be considered later
as an optimization after the owned-task boundary is in place.

`u32` is passed through R numeric (`double`). `BIGINT`, `UBIGINT`,
`HUGEINT`, and `UHUGEINT` use exact Rducks integer classes backed by
canonical decimal strings.

## Current scope

Rducks currently builds `rducks.duckdb_extension` at install time, loads
it into DuckDB with `rducks_enable()`, and registers scalar or
vectorized R UDFs with `rducks_register()`. Implemented execution plans
are `arrow_r + serial`, `arrow_r + inproc_concurrent`,
`arrow_c + serial`, `arrow_c + inproc_concurrent`, and
`arrow_ipc + multiprocess_parallel`. The input/output type set is
`BOOLEAN`, `TINYINT`, `UTINYINT`, `SMALLINT`, `USMALLINT`, `INTEGER`,
`UINTEGER`, `BIGINT`, `UBIGINT`, `FLOAT`, `DOUBLE`, `VARCHAR`, `BLOB`,
`DATE`, `TIME`, `TIMESTAMP`, `HUGEINT`, `UHUGEINT`, `UUID`, `INTERVAL`,
`BIT`, `DECIMAL(width, scale)`, `ENUM(levels)`, and `UNION(...)`.
Composite inputs and outputs are accepted as constructed type objects
such as `TYPE[]`, `TYPE[N]`, `STRUCT(...)`, and `MAP(...)`, recursively
over supported child types. The default `mode = "scalar"` calls R once
per DuckDB row; `mode = "vectorized"` calls R once per DuckDB chunk.
Registration also supports `null_handling`, `exception_handling`, and
`side_effects` controls.

Rducks scalar UDFs require R API work to happen on the recorded main R
thread. This is R’s thread-affinity rule, not a DuckDB data-race issue.
Register UDFs from the registration-safe configuration created by
`rducks_enable(con, threads = "single")`, or by setting
`external_threads=1` and `PRAGMA threads=1` before registration. After
registration, either keep the `single` backend for direct execution or
call `rducks_enable_inproc()` for the official same-process queued
backend. The queue does not make R callbacks parallel; it routes chunk
requests through the main R execution lane and reports timeouts instead
of hanging if that lane is unavailable.

Rducks also provides explicit R value classes for exact or
DuckDB-specific values: `rducks_bigint()`, `rducks_ubigint()`,
`rducks_uuid()`, `rducks_interval()`, `rducks_decimal()`,
`rducks_hugeint()`, `rducks_uhugeint()`, `rducks_bits()`,
`rducks_enum()`, and `rducks_union()`. These classes preserve exact
representation at the scalar-mode R function boundary. Constructed
DuckDB type objects are formal S7-backed Rducks descriptors with
structural validation via `rducks_is_type()`. Descriptors are recursive,
so lists, arrays, structs, maps, enums, decimals, and unions can be
nested through the constructors rather than quoted type strings.
`rducks_check_argument()` and `rducks_check_return()` can validate
ordinary R values against those descriptors before marshalling.

### Execution mode semantics

The table below is produced by `rducks_mode_semantics()`.

| mode         | status      | call_granularity            | input_shape                                        | return_shape                                                          | length_semantics                                                   | threading                                                                                                                                                                   | copy_semantics                                                                                                                                                            |
|:-------------|:------------|:----------------------------|:---------------------------------------------------|:----------------------------------------------------------------------|:-------------------------------------------------------------------|:----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|:--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `scalar`     | implemented | one R call per row          | one scalar/composite R value per declared argument | one scalar/composite R value compatible with the declared return type | one output value per R function call                               | R API work for arrow_r/arrow_c runs on the recorded main R thread; arrow_ipc + multiprocess_parallel evaluates scalar rows inside Future workers after Arrow IPC encoding   | DuckDB chunks are exported/imported through Arrow C Data for in-process plans; arrow_ipc plans copy chunk/task payloads into Arrow IPC raw bytes before process transport |
| `vectorized` | implemented | one R call per DuckDB chunk | one R vector/list-column per declared argument     | one R vector/list of values compatible with the declared return type  | return length must equal the number of evaluated rows in the chunk | same execution-plan threading rules as scalar mode for arrow_r/arrow_c; arrow_ipc + multiprocess_parallel offloads vectorized chunk work through the current future backend | DuckDB chunks are exported/imported through Arrow C Data; arrow_ipc plans copy chunk/task payloads into Arrow IPC raw bytes before process transport                      |

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

| argument_type                        | r_type          | r_value_passed_to_fun                                  | sql_null_in_function | copy_semantics                  | notes                                                            |
|:-------------------------------------|:----------------|:-------------------------------------------------------|:---------------------|:--------------------------------|:-----------------------------------------------------------------|
| `BOOLEAN`                            | logical         | logical(1)                                             | NA                   | boxed scalar                    |                                                                  |
| `TINYINT`                            | integer         | integer(1)                                             | NA_integer\_         | boxed scalar                    |                                                                  |
| `UTINYINT`                           | integer         | integer(1)                                             | NA_integer\_         | boxed scalar                    |                                                                  |
| `SMALLINT`                           | integer         | integer(1)                                             | NA_integer\_         | boxed scalar                    |                                                                  |
| `USMALLINT`                          | integer         | integer(1)                                             | NA_integer\_         | boxed scalar                    |                                                                  |
| `INTEGER`                            | integer         | integer(1)                                             | NA_integer\_         | boxed scalar                    |                                                                  |
| `UINTEGER`                           | numeric         | numeric(1)                                             | NA_real\_            | boxed scalar                    | R double                                                         |
| `BIGINT`                             | rducks_bigint   | rducks_bigint scalar                                   | NULL                 | boxed exact Rducks value object | exact signed 64-bit integer string                               |
| `UBIGINT`                            | rducks_ubigint  | rducks_ubigint scalar                                  | NULL                 | boxed exact Rducks value object | exact unsigned 64-bit integer string                             |
| `FLOAT`                              | numeric         | numeric(1)                                             | NA_real\_            | boxed scalar                    | widened to R double                                              |
| `DOUBLE`                             | numeric         | numeric(1)                                             | NA_real\_            | boxed scalar                    |                                                                  |
| `VARCHAR`                            | character       | character(1)                                           | NA_character\_       | string copied into R            | string copied into R                                             |
| `BLOB`                               | raw             | raw vector                                             | NULL                 | bytes copied into R             | bytes copied into R                                              |
| `DATE`                               | Date            | Date scalar                                            | Date NA              | boxed scalar                    | days since 1970-01-01                                            |
| `TIME`                               | numeric         | numeric(1) seconds                                     | NA_real\_            | boxed scalar                    | microseconds converted to seconds                                |
| `TIMESTAMP`                          | POSIXct         | POSIXct scalar                                         | POSIXct NA           | boxed scalar                    | microseconds converted to seconds                                |
| `HUGEINT`                            | rducks_hugeint  | rducks_hugeint                                         | NULL                 | boxed exact Rducks value object | exact Rducks value class                                         |
| `UHUGEINT`                           | rducks_uhugeint | rducks_uhugeint                                        | NULL                 | boxed exact Rducks value object | exact Rducks value class                                         |
| `UUID`                               | rducks_uuid     | rducks_uuid                                            | NULL                 | boxed exact Rducks value object | exact Rducks value class                                         |
| `INTERVAL`                           | rducks_interval | rducks_interval                                        | NULL                 | boxed exact Rducks value object | exact Rducks value class                                         |
| `BIT`                                | rducks_bits     | rducks_bits                                            | NULL                 | boxed exact Rducks value object | exact Rducks value class                                         |
| `INTEGER[]`                          | vector          | integer vector                                         | NULL                 | R vector allocation             | homogeneous scalar children use atomic vectors                   |
| `BIGINT[3]`                          | vector          | rducks_bigint vector of length 3                       | NULL                 | R vector allocation             | fixed-size array; homogeneous scalar children use atomic vectors |
| `STRUCT(a UUID, b DECIMAL(10, 2))`   | list            | named list of fields                                   | NULL                 | recursive R allocation          | recursive field mapping                                          |
| `MAP(VARCHAR, INTEGER)`              | list            | list(keys = character vector, values = integer vector) | NULL                 | recursive R allocation          | keys and values use sequence mapping                             |
| `DECIMAL(10, 2)`                     | rducks_decimal  | rducks_decimal scalar                                  | NULL                 | boxed exact Rducks value object | exact fixed-point value class                                    |
| `ENUM('red', 'blue')`                | rducks_enum     | rducks_enum scalar                                     | NULL                 | boxed exact Rducks value object | factor with enum levels                                          |
| `UNION(code INTEGER, label VARCHAR)` | rducks_union    | rducks_union object                                    | NULL                 | boxed exact Rducks value object | tagged value object                                              |

</details>

### NULL, NA, NaN, Inf, and value-class semantics

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

| duckdb_type                                | sql_null_special | r_na_return                                                                        | r_nan_return                       | r_inf_return                       | binary_ops                                                                                      | error_semantics                                                                     |
|:-------------------------------------------|:-----------------|:-----------------------------------------------------------------------------------|:-----------------------------------|:-----------------------------------|:------------------------------------------------------------------------------------------------|:------------------------------------------------------------------------------------|
| `INTEGER`                                  | NA_integer\_     | NA_integer\_ -\> SQL NULL                                                          | error                              | error                              | no Rducks-specific binary ops                                                                   | NaN, Inf, fractional, and out-of-range return values error                          |
| `DOUBLE`                                   | NA_real\_        | NA_real\_ -\> SQL NULL                                                             | preserved as DuckDB NaN            | preserved as DuckDB +/-Inf         | ordinary R numeric semantics in the R function                                                  | NA is NULL; NaN and Inf are valid DOUBLE values                                     |
| `BIGINT`                                   | NULL             | rducks_bigint(NA) -\> SQL NULL                                                     | error                              | error                              | rducks_bigint +, -, comparisons; NA propagates; range errors remain errors                      | non-integer strings, numeric NaN/Inf, and out-of-range values error                 |
| `UBIGINT`                                  | NULL             | rducks_ubigint(NA) -\> SQL NULL                                                    | error                              | error                              | rducks_ubigint +, -, comparisons; NA propagates; unsigned underflow/range errors remain errors  | non-integer strings, numeric NaN/Inf, and out-of-range values error                 |
| `HUGEINT`                                  | NULL             | rducks_hugeint(NA) -\> SQL NULL                                                    | error                              | error                              | rducks_hugeint +, -, comparisons; NA propagates; range errors remain errors                     | non-integer strings, numeric NaN/Inf, and out-of-range values error                 |
| `UHUGEINT`                                 | NULL             | rducks_uhugeint(NA) -\> SQL NULL                                                   | error                              | error                              | rducks_uhugeint +, -, comparisons; NA propagates; unsigned underflow/range errors remain errors | non-integer strings, numeric NaN/Inf, and out-of-range values error                 |
| `UUID`                                     | NULL             | rducks_uuid(NA) -\> SQL NULL                                                       | error                              | error                              | no Rducks-specific binary ops                                                                   | NA UUID values are NULL; malformed UUID text errors                                 |
| `INTERVAL`                                 | NULL             | any NA component in rducks_interval() -\> SQL NULL                                 | error                              | error                              | rducks_interval + and -; NA components propagate; component overflow remains an error           | NaN/Inf components and months/days/micros outside DuckDB ranges error               |
| `BIT`                                      | NULL             | no NA bit payload; use R NULL for SQL NULL                                         | error                              | error                              | rducks_bits &, \|, !, rducks_bits_xor(); NA bits are rejected                                   | BIT inputs must contain only 0/1 or TRUE/FALSE; NA bits error                       |
| `DECIMAL(10, 2)`                           | NULL             | rducks_decimal(NA, width, scale) -\> SQL NULL                                      | error                              | error                              | rducks_decimal +, -, comparisons; NA propagates; matching scales are required                   | NaN/Inf numeric inputs, scale/width mismatch, and DECIMAL arithmetic overflow error |
| `ENUM('red', 'blue')`                      | NULL             | rducks_enum(NA, levels) -\> SQL NULL                                               | not applicable                     | not applicable                     | no Rducks-specific ENUM binary ops                                                              | values outside the declared enum levels error                                       |
| `UNION(code INTEGER, label VARCHAR)`       | NULL             | no missing tag; NA in the selected child follows that child semantics              | recursive selected-child semantics | recursive selected-child semantics | no Rducks-specific UNION binary ops                                                             | missing, empty, or unknown tags and selected-child mismatches error                 |
| `STRUCT(amount DECIMAL(10, 2), id BIGINT)` | NULL             | field values recurse; scalar field NA values become SQL NULL fields                | recursive child semantics          | recursive child semantics          | no descriptor-level Rducks binary ops; child value classes keep their own ops                   | missing fields and field type mismatches error                                      |
| `MAP(VARCHAR, INTEGER)`                    | NULL             | values recurse; scalar NA values become SQL NULL value entries; NULL/NA keys error | recursive child semantics          | recursive child semantics          | no descriptor-level Rducks binary ops; child value classes keep their own ops                   | keys/values length mismatch, NULL/NA keys, and child type mismatches error          |

</details>

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
#> 1 0.2655087
#> 2 0.3721239
#> 3 0.5728534
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
