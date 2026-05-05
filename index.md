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
  calls.
- `arrow_ipc`: process-isolated R execution using Arrow IPC
  request/result payloads and a generic Future backend.

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

### Arrow conversion setting

[`rducks_enable()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable.md)
sets DuckDB’s `arrow_lossless_conversion=true` setting on the user
connection, and the Rducks extension also sets it on its own internal
DuckDB connection. Rducks uses DuckDB’s Arrow C Data conversion APIs for
several execution plans, and this setting tells DuckDB to preserve
DuckDB-specific type identity in Arrow metadata when possible instead of
exporting only a more generic Arrow representation. This matters for
types such as `UUID`, `BIT`, `HUGEINT`/`UHUGEINT`,
`TIME WITH TIME ZONE`, and JSON aliases. It does not change stored
DuckDB values or SQL evaluation; it only affects DuckDB-to-Arrow
conversion used at the Rducks boundary.

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
#> 1 scalar        298ms      3.35    1.97MB
#> 2 vectorized    243ms      4.13    2.34MB
```

## Execution plans

Execution plans choose the marshalling implementation and concurrency
contract for a connection. Registration remains semantic: name,
function, mode, types, NULL handling, exception handling, and
side-effect flag.

| Plan | Scalar | Vectorized | Notes |
|----|----|----|----|
| `arrow_r + serial` | implemented | implemented | reference implementation |
| `arrow_r + inproc_concurrent` | implemented | implemented | queued same-process callbacks; R API work stays on the recorded main R thread |
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
serializes R API work on the recorded main R thread.

DuckDB interprets `external_threads` as threads supplied by the caller
rather than DuckDB-created worker threads. For stress tests, prefer
settings such as `threads = 4, external_threads = 1`; do not set
`external_threads = threads` unless you intentionally want no
DuckDB-created worker pool.

The example below uses a DuckDB table scan, not an Rducks table source.
It is a diagnostic, not a speed benchmark. The `rducks_thread_is_main()`
probe shows whether DuckDB evaluated a scan on the recorded main R
thread or on DuckDB worker threads. The UDF query then runs over the
same table and the queue counters show how many DuckDB chunks were
routed through the in-process queue. Do not infer an expected speed gain
from this mode: R API work is still serialized on the recorded main R
thread, and the queue plus Arrow marshalling add overhead.

``` r

reg_inproc_plus_one <- rducks_register(
  con,
  name = "r_inproc_plus_one",
  fun = function(x) x + 1,
  args = DOUBLE,
  returns = DOUBLE
)

rducks_enable_inproc(con, threads = 4, external_threads = 1)
rducks_current_execution_plan(con)$plan_id
#> [1] "arrow_r+inproc_concurrent"

dbGetQuery(
  con,
  "SELECT current_setting('threads') AS threads, current_setting('external_threads') AS external_threads"
)
#>   threads external_threads
#> 1       4                1

inproc_n <- 200000L
invisible(DBI::dbExecute(
  con,
  sprintf(
    "CREATE TEMP TABLE inproc_input AS SELECT i::DOUBLE AS x, i::UBIGINT AS tid FROM range(%d) AS t(i)",
    inproc_n
  )
))

dbGetQuery(
  con,
  paste(
    "SELECT count(*)::VARCHAR AS rows,",
    "sum(CASE WHEN rducks_thread_is_main(tid) THEN 1 ELSE 0 END)::VARCHAR AS main_thread_rows,",
    "(count(*) - sum(CASE WHEN rducks_thread_is_main(tid) THEN 1 ELSE 0 END))::VARCHAR AS worker_thread_rows",
    "FROM inproc_input"
  )
)
#>     rows main_thread_rows worker_thread_rows
#> 1 200000           122880              77120

stats0 <- rducks_inproc_stats(con)
dbGetQuery(con, "SELECT sum(r_inproc_plus_one(x)) AS total FROM inproc_input")
#>         total
#> 1 20000100000
stats1 <- rducks_inproc_stats(con)
stats1 - stats0
#>   submitted executed timeouts
#> 1        98       98        0

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
  "ripc_collect_max_batch", "ripc_submit_wave_max",
  "ripc_collect_ready_max"
)]
#>             name       mode                         plan_id evaluator
#> 1 r_ipc_plus_one vectorized arrow_ipc+multiprocess_parallel      RIPC
#>   arrow_ipc_chunks ripc_collect_batches ripc_collect_requests
#> 1                5                    5                     5
#>   ripc_collect_max_batch ripc_submit_wave_max ripc_collect_ready_max
#> 1                      1                    1                      1
```

For `arrow_ipc + multiprocess_parallel`, the native extension submits
Arrow IPC chunk work through the Future-backed RIPC path and imports the
returned Arrow IPC result into DuckDB. When a RIPC callback runs on the
recorded main R thread, it can submit its own chunk and queued worker
chunks before grouped collection. The `ripc_collect_max_batch`,
`ripc_submit_wave_max`, and `ripc_collect_ready_max` counters report
native queue batch/wave sizes.

### DuckDB table-scan no-op benchmark

This benchmark uses a DuckDB table scan over a table created from
[`range()`](https://rdrr.io/r/base/range.html), not an Rducks table
source. The `parallel_probe` query verifies that DuckDB actually uses a
non-main worker thread for this table scan before timing the no-op UDF.

``` r

arrow_ipc_noop_benchmark <- local({
  future::plan(future.mirai::mirai_multisession, workers = 4)

  bench_con <- DBI::dbConnect(
    duckdb::duckdb(config = list(allow_unsigned_extensions = "true")),
    dbdir = ":memory:"
  )
  on.exit(DBI::dbDisconnect(bench_con, shutdown = TRUE), add = TRUE)

  rducks_enable(bench_con, threads = "single")
  bench_plan <- rducks_execution_plan(
    "arrow_ipc", "multiprocess_parallel",
    future_timeout = 120
  )

  bench_n <- 200000L
  DBI::dbExecute(
    bench_con,
    sprintf(
      "CREATE TABLE bench_input AS SELECT i::BIGINT AS i FROM range(%d) AS t(i)",
      bench_n
    )
  )
  DBI::dbExecute(bench_con, "PRAGMA threads=5")
  DBI::dbExecute(bench_con, "SET external_threads=1")
  parallel_probe <- DBI::dbGetQuery(
    bench_con,
    paste(
      "SELECT count(*) AS rows,",
      "sum(CASE WHEN rducks_thread_is_main(i::UBIGINT) THEN 1 ELSE 0 END) AS main_thread_rows",
      "FROM bench_input"
    )
  )
  stopifnot(parallel_probe$main_thread_rows[[1L]] < parallel_probe$rows[[1L]])

  rducks_set_execution_plan(bench_con, bench_plan, threads = 1L, external_threads = 1L)
  invisible(rducks_register(
    bench_con,
    name = "r_ipc_noop_bench",
    fun = function(x) as.numeric(x) + 1,
    args = BIGINT,
    returns = DOUBLE,
    mode = "vectorized",
    side_effects = FALSE
  ))

  expected <- DBI::dbGetQuery(bench_con, "SELECT sum(i + 1) AS x FROM bench_input")$x[[1L]]
  sql <- "SELECT sum(r_ipc_noop_bench(i)) AS x FROM bench_input"

  time_query <- function(threads) {
    rducks_set_execution_plan(
      bench_con, bench_plan,
      threads = threads,
      external_threads = 1L
    )
    invisible(DBI::dbGetQuery(bench_con, sql)) # warm this execution shape
    elapsed <- system.time(out <- DBI::dbGetQuery(bench_con, sql))[["elapsed"]]
    stopifnot(isTRUE(all.equal(as.numeric(out$x), as.numeric(expected))))
    elapsed
  }

  elapsed <- data.frame(
    mode = c("threads=1", "threads=5"),
    elapsed_seconds = c(time_query(1L), time_query(5L))
  )
  elapsed$speedup_vs_threads_1 <- elapsed$elapsed_seconds[[1L]] / elapsed$elapsed_seconds

  diagnostics <- rducks_explain_udf(bench_con, "r_ipc_noop_bench")[, c(
    "queue_pending_max", "ripc_inflight_max", "ripc_submit_wave_max",
    "ripc_collect_ready_max", "ripc_collect_max_batch"
  )]

  list(
    parallel_probe = parallel_probe,
    elapsed = elapsed,
    diagnostics = diagnostics
  )
})

arrow_ipc_noop_benchmark$parallel_probe
#>    rows main_thread_rows
#> 1 2e+05                0
arrow_ipc_noop_benchmark$elapsed
#>        mode elapsed_seconds speedup_vs_threads_1
#> 1 threads=1           9.235             1.000000
#> 2 threads=5           6.500             1.420769
arrow_ipc_noop_benchmark$diagnostics
#>   queue_pending_max ripc_inflight_max ripc_submit_wave_max
#> 1                 1                 2                    2
#>   ripc_collect_ready_max ripc_collect_max_batch
#> 1                      2                      2
```

### DuckDB multi-file sleep benchmark

This benchmark uses DuckDB input: four temporary CSV files read by
DuckDB’s `read_csv()` table function. The UDF sleeps for 0.50 seconds
once per vectorized DuckDB chunk. The probe again checks that the source
runs on a non-main worker thread before timing the UDF query.

``` r

arrow_ipc_sleep_benchmark <- local({
  future::plan(future.mirai::mirai_multisession, workers = 4)

  bench_con <- DBI::dbConnect(
    duckdb::duckdb(config = list(allow_unsigned_extensions = "true")),
    dbdir = ":memory:"
  )
  on.exit(DBI::dbDisconnect(bench_con, shutdown = TRUE), add = TRUE)

  rducks_enable(bench_con, threads = "single")
  bench_plan <- rducks_execution_plan(
    "arrow_ipc", "multiprocess_parallel",
    future_timeout = 120
  )
  rducks_set_execution_plan(bench_con, bench_plan)

  csv_dir <- tempfile("rducks-csv-bench-")
  dir.create(csv_dir)
  csv_files <- file.path(csv_dir, paste0("part", seq_len(4L), ".csv"))
  start <- 0L
  for (file in csv_files) {
    values <- start + seq_len(1024L) - 1L
    writeLines(c("i", as.character(values)), file)
    start <- start + 1024L
  }
  csv_paths <- paste(sprintf("'%s'", csv_files), collapse = ",")
  csv_source <- sprintf(
    "read_csv([%s], types={'i':'BIGINT'}, header=true)",
    csv_paths
  )

  invisible(rducks_register(
    bench_con,
    name = "r_ipc_sleep_half_second_bench",
    fun = function(x) {
      Sys.sleep(0.50)
      as.numeric(x) + 1
    },
    args = BIGINT,
    returns = DOUBLE,
    mode = "vectorized",
    side_effects = TRUE
  ))

  DBI::dbExecute(bench_con, "PRAGMA threads=5")
  DBI::dbExecute(bench_con, "SET external_threads=1")
  parallel_probe <- DBI::dbGetQuery(
    bench_con,
    sprintf(
      paste(
        "SELECT count(*) AS rows,",
        "sum(CASE WHEN rducks_thread_is_main(i::UBIGINT) THEN 1 ELSE 0 END) AS main_thread_rows",
        "FROM %s"
      ),
      csv_source
    )
  )
  stopifnot(parallel_probe$main_thread_rows[[1L]] < parallel_probe$rows[[1L]])

  expected <- 4096L * 4097L / 2
  sql <- sprintf("SELECT sum(r_ipc_sleep_half_second_bench(i)) AS x FROM %s", csv_source)

  time_query <- function(threads) {
    rducks_set_execution_plan(
      bench_con, bench_plan,
      threads = threads,
      external_threads = 1L
    )
    invisible(DBI::dbGetQuery(bench_con, sql)) # warm this execution shape
    elapsed <- system.time(out <- DBI::dbGetQuery(bench_con, sql))[["elapsed"]]
    stopifnot(isTRUE(all.equal(as.numeric(out$x), expected)))
    elapsed
  }

  elapsed <- data.frame(
    mode = c("threads=1", "threads=5"),
    elapsed_seconds = c(time_query(1L), time_query(5L))
  )
  elapsed$speedup_vs_threads_1 <- elapsed$elapsed_seconds[[1L]] / elapsed$elapsed_seconds

  diagnostics <- rducks_explain_udf(bench_con, "r_ipc_sleep_half_second_bench")[, c(
    "queue_pending_max", "ripc_inflight_max", "ripc_submit_wave_max",
    "ripc_collect_ready_max", "ripc_collect_max_batch"
  )]

  list(
    parallel_probe = parallel_probe,
    elapsed = elapsed,
    diagnostics = diagnostics
  )
})

arrow_ipc_sleep_benchmark$parallel_probe
#>   rows main_thread_rows
#> 1 4096             1024
arrow_ipc_sleep_benchmark$elapsed
#>        mode elapsed_seconds speedup_vs_threads_1
#> 1 threads=1           2.355             1.000000
#> 2 threads=5           0.700             3.364286
arrow_ipc_sleep_benchmark$diagnostics
#>   queue_pending_max ripc_inflight_max ripc_submit_wave_max
#> 1                 3                 4                    4
#>   ripc_collect_ready_max ripc_collect_max_batch
#> 1                      4                      4
```

These timings are diagnostics, not a portable performance promise. In
particular, cheap UDFs can be slower with `multiprocess_parallel`
because Arrow IPC and Future scheduling overhead dominate much of the
work being done.

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

## DuckDB C extension ABI surface

The extension entrypoint receives the DuckDB database handle from
DuckDB’s extension access struct, stores it in a per-database runtime
record, and opens an extension-owned DuckDB connection for native
callback support. On extension reload, Rducks verifies that the active
connection has the SQL surface registered and re-registers it when
needed.

The following unstable DuckDB C extension ABI entries are derived by
scanning the Rducks extension C sources and matching `duckdb_*` calls
against the versioned sections of the bundled `duckdb_extension.h`:

| ABI group | Functions used | Count |
|----|----|---:|
| `unstable_new_arrow_functions` | `duckdb_data_chunk_from_arrow`, `duckdb_data_chunk_to_arrow`, `duckdb_destroy_arrow_converted_schema`, `duckdb_schema_from_arrow`, `duckdb_to_arrow_schema` | 5 |
| `unstable_new_error_data_functions` | `duckdb_destroy_error_data`, `duckdb_error_data_has_error`, `duckdb_error_data_message` | 3 |
| `unstable_new_open_connect_functions` | `duckdb_client_context_get_connection_id`, `duckdb_connection_get_arrow_options`, `duckdb_destroy_arrow_options`, `duckdb_destroy_client_context` | 4 |
| `unstable_new_scalar_function_functions` | `duckdb_scalar_function_bind_get_extra_info`, `duckdb_scalar_function_bind_set_error`, `duckdb_scalar_function_get_client_context`, `duckdb_scalar_function_set_bind`, `duckdb_scalar_function_set_bind_data`, `duckdb_scalar_function_set_bind_data_copy` | 6 |
| `unstable_new_scalar_function_state_functions` | `duckdb_scalar_function_get_state`, `duckdb_scalar_function_init_get_bind_data`, `duckdb_scalar_function_init_get_client_context`, `duckdb_scalar_function_init_get_extra_info`, `duckdb_scalar_function_init_set_error`, `duckdb_scalar_function_init_set_state`, `duckdb_scalar_function_set_init` | 7 |
| `unstable_new_vector_functions` | `duckdb_create_selection_vector`, `duckdb_destroy_selection_vector`, `duckdb_selection_vector_get_data_ptr`, `duckdb_vector_copy_sel`, `duckdb_vector_reference_vector` | 5 |
