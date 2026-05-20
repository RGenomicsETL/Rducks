
<!-- README.md is generated from README.Rmd. Please edit README.Rmd. -->

# Rducks

[![R-CMD-check](https://github.com/sounkou-bioinfo/Rducks/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/sounkou-bioinfo/Rducks/actions/workflows/R-CMD-check.yaml)
[![R-universe](https://sounkou-bioinfo.r-universe.dev/badges/Rducks)](https://sounkou-bioinfo.r-universe.dev/Rducks)
[![Lifecycle:
experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)

Rducks registers R functions as DuckDB SQL functions using a
package-managed [DuckDB C
extension](https://duckdb.org/docs/stable/extensions/overview). The
extension records the DuckDB database instance at load time and keeps
extension-owned connections for native registration callbacks and query
streaming. It is built around explicit type descriptors, DuckDB Arrow C
Data/[nanoarrow](https://arrow.apache.org/nanoarrow/latest/r/)
marshalling, and a strict rule that R object work runs on the recorded R
thread unless it is intentionally moved to R worker processes through
the Arrow IPC plan.

Rducks is organized around DuckDB function kind, scalar-UDF evaluation
mode, execution plan, and R-side query consumption. Scalar UDFs are
registered with `rducks_register_scalar_udf()` and choose
`mode = "scalar"` for one R call per row or `mode = "vectorized"` for
one R call per DuckDB chunk. Execution plans select the
marshalling/concurrency backend (`arrow_r`, `arrow_c`, or `arrow_ipc`).
With `arrow_ipc`, the extension uses the [NNG C
API](https://nng.nanomsg.org/) for native request/reply transport; the
default local worker lifecycle is launched by
[mirai](https://mirai.r-lib.org/), with optional
[mori](https://shikokuchuo.net/mori/) sharing for selected globals.
Aggregates use `rducks_register_aggregate()`, table functions use
`rducks_register_table()` with optional `rducks_table_stream()`
producers, and query consumers can use `rducks_query_stream()` for
native streaming batches.

## How it works

Rducks loads a small DuckDB extension that records the database instance
and keeps extension-owned connections for registration callbacks, table
scans, and query streaming. R closures are preserved while DuckDB
catalog metadata can call them, and scalar calls either run on the
recorded R thread or are marshalled to explicit R worker processes by
the Arrow IPC plan.

The “Arrow dance” is the shared boundary. DuckDB produces vectors in
standard chunks; Rducks exposes those chunks through DuckDB Arrow C
Data, uses [nanoarrow](https://arrow.apache.org/nanoarrow/latest/r/) to
materialize typed R inputs, calls the R function, and writes typed
results back to DuckDB. The `arrow_r` plan keeps most conversion in
R/nanoarrow, `arrow_c` uses native C materialization for supported
types, and `arrow_ipc` serializes owned Arrow IPC request/result bytes
over [NNG](https://nng.nanomsg.org/) so separate R worker processes can
do the R evaluation. Dynamic omitted-`args` UDFs still bind concrete
DuckDB types at the SQL call site before this marshalling begins.

A future transport could use DuckDB’s [Quack-style
format](https://github.com/duckdb/duckdb-quack): DuckDB
`BinarySerializer` messages carrying logical types and `DataChunk`
payloads, rather than Arrow IPC bytes. That could remove some Arrow
encode/decode work and align worker transport more closely with DuckDB’s
native chunk model. It is not a runtime dependency today; adopting it
would require a versioned C implementation, strict compatibility checks,
and the same explicit ownership and R-thread rules that the Arrow paths
enforce now.

## Quick start

``` r
library(DBI)
library(duckdb)
library(Rducks)

con <- dbConnect(duckdb(config = list(allow_unsigned_extensions = "true")))
rducks_enable(con, threads = "single")

score_udf <- rducks_register_scalar_udf(
  con,
  name = "r_score",
  fun = function(row) {
    bonus <- if (identical(row$label, "high")) 100 else 0
    list(
      score = as.double(row$x + bonus),
      parts = as.double(c(row$x, bonus))
    )
  },
  returns = STRUCT(score = DOUBLE, parts = DOUBLE[]),
  side_effects = TRUE
)

dbGetQuery(con, "
  WITH input AS (
    SELECT struct_pack(x := x::DOUBLE, label := label) AS payload
    FROM (VALUES (2, 'low'), (21, 'high')) AS t(x, label)
  ), scored AS (
    SELECT r_score(payload) AS result FROM input
  )
  SELECT result.score AS score, result.parts AS parts
  FROM scored
")
#>   score   parts
#> 1     2    2, 0
#> 2   121 21, 100
```

`r_score()` omits `args`, so DuckDB registers it as a dynamic varargs
scalar UDF. At this SQL call site DuckDB binds a concrete
`STRUCT(x DOUBLE, label VARCHAR)` input, and the return type is
explicit: a struct containing a `DOUBLE` and a `DOUBLE[]`. Rducks
materializes dynamic inputs as if the signature had been declared with
`args = ...`. Use `args = NULL` only for a true zero-argument UDF.

The returned registration object records the normalized signature and
options; DuckDB owns the catalog function after registration. Dropping
the R object does not unregister the SQL function. Registering the same
SQL name/signature again replaces the callable implementation. Use
`side_effects = TRUE` for functions with counters, randomness, I/O,
mutation, sleeps, or other effects so DuckDB does not optimize them as
pure expressions.

## Lifecycle

`rducks_release(con)` detaches connection-local Rducks state and stops
Rducks-launched local IPC workers when the last attachment for the
DuckDB runtime is released. It does not drop DuckDB catalog functions or
release closures still owned by native catalog metadata. For
deterministic cleanup, call it before `DBI::dbDisconnect(con)`; to
replace a scalar UDF, register the same SQL name/signature again.

## Type descriptors

Rducks descriptors are used for scalar-UDF returns, declared scalar-UDF
inputs, and aggregate inputs/returns. They include DuckDB scalar types,
exact value classes such as `UUID`, `HUGEINT`, `DECIMAL(width, scale)`,
`INTERVAL`, `BIT`, `ENUM(levels)`, and composite descriptors such as
`LIST(TYPE)`, `ARRAY(TYPE, n)`, `STRUCT(...)`, `MAP(key, value)`, and
`UNION(...)`.

``` r
nested_type <- STRUCT(
  id = INTEGER,
  label = ENUM(c("low", "high")),
  payload = UNION(code = INTEGER, note = VARCHAR),
  values = LIST(DECIMAL(10, 2))
)

rducks_is_type(nested_type)
#> [1] TRUE
cat(strwrap(rducks_type_sql(nested_type), width = 70), sep = "\n")
#> STRUCT(id INTEGER, label ENUM('low', 'high'), payload UNION(code
#> INTEGER, note VARCHAR), values DECIMAL(10, 2)[])
rducks_type_child_names(nested_type)
#> [1] "id"      "label"   "payload" "values"
```

## Scalar UDFs

Scalar mode calls the R function once per logical row. Vectorized mode
calls the R function once per DuckDB chunk with one R vector or
list-column per declared or dynamically bound argument.

``` r
scalar_plus_one_udf <- rducks_register_scalar_udf(
  con,
  name = "r_scalar_plus_one",
  fun = function(x) x + 1,
  args = DOUBLE,
  returns = DOUBLE,
  mode = "scalar",
  side_effects = TRUE
)

vec_plus_one_udf <- rducks_register_scalar_udf(
  con,
  name = "r_vec_plus_one",
  fun = function(x) x + 1,
  args = DOUBLE,
  returns = DOUBLE,
  mode = "vectorized",
  side_effects = TRUE
)

dbGetQuery(con, "SELECT sum(r_vec_plus_one(i::DOUBLE)) AS total FROM range(5) AS t(i)")
#>   total
#> 1    15
```

Dynamic omitted arguments are not a guessing path. They are bind-time
descriptors. The same R function below is registered once with an
explicit nested signature and once as dynamic varargs; both calls see
the same typed R value.

``` r
nested_summary <- function(x) {
  paste0(x$id, ":", x$label, ":", x$payload$tag, "=", x$payload$value)
}

nested_declared_udf <- rducks_register_scalar_udf(
  con,
  name = "r_nested_declared",
  fun = nested_summary,
  args = STRUCT(
    id = INTEGER,
    label = ENUM(c("low", "high")),
    payload = UNION(code = INTEGER, note = VARCHAR)
  ),
  returns = VARCHAR,
  null_handling = "special"
)

nested_dynamic_udf <- rducks_register_scalar_udf(
  con,
  name = "r_nested_dynamic",
  fun = nested_summary,
  returns = VARCHAR,
  null_handling = "special"
)

nested_sql <- "
  struct_pack(
    id := 7::INTEGER,
    label := 'high'::ENUM('low', 'high'),
    payload := union_value(note := 'ok')::UNION(code INTEGER, note VARCHAR)
  )
"

nested_query <- sprintf(
  paste(
    "SELECT",
    "  r_nested_declared(%1$s) AS declared,",
    "  r_nested_dynamic(%1$s) AS dynamic",
    sep = "\n"
  ),
  nested_sql
)
dbGetQuery(con, nested_query)
#>         declared        dynamic
#> 1 7:high:note=ok 7:high:note=ok
```

With `null_handling = "default"`, a top-level SQL `NULL` input produces
a SQL `NULL` output without calling R. With `null_handling = "special"`,
top-level SQL `NULL` values are passed as type-specific R missing
values. Nested NULLs are part of the value: scalar children usually
become typed `NA`, while nested composite NULLs become `NULL`.

``` r
null_special_udf <- rducks_register_scalar_udf(
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

For type-by-type details, use the exported reference tables:

``` r
rducks_mode_semantics()[, c("mode", "call_granularity", "input_shape")]
#>         mode            call_granularity
#> 1     scalar          one R call per row
#> 2 vectorized one R call per DuckDB chunk
#>                                                               input_shape
#> 1 one scalar/composite R value per declared or dynamically bound argument
#> 2     one R vector/list-column per declared or dynamically bound argument
mapping <- rducks_argument_type_mapping(list(
  INTEGER,
  UUID,
  DECIMAL(10, 2),
  STRUCT(a = INTEGER[])
))
mapping[, c("duckdb_type", "r_value_class", "special_null_argument")]
#>           duckdb_type  r_value_class special_null_argument
#> 1             INTEGER        integer           NA_integer_
#> 2                UUID    rducks_uuid                  NULL
#> 3      DECIMAL(10, 2) rducks_decimal                  NULL
#> 4 STRUCT(a INTEGER[])           list                  NULL
```

## Aggregates, table functions, and query streams

### Aggregate functions

`rducks_register_aggregate()` registers R-backed DuckDB aggregates.
Aggregate state is an R object preserved by the extension, not a
serialized blob. The callbacks run on the recorded R thread and are not
controlled by scalar-UDF execution plans.

``` r
sum_i32_aggregate <- rducks_register_aggregate(
  con,
  name = "r_sum_i32",
  update = function(state, x) {
    if (is.null(state)) state <- 0L
    as.integer(state + x)
  },
  finalize = function(state) if (is.null(state)) NA_integer_ else state,
  args = INTEGER,
  returns = INTEGER
)

dbGetQuery(
  con,
  paste(
    "SELECT r_sum_i32(i) AS total",
    "FROM (VALUES (1::INTEGER), (2::INTEGER), (NULL::INTEGER)) t(i)"
  )
)
#>   total
#> 1     3
```

### Table functions

`rducks_register_table()` infers the number of SQL arguments from the R
function formals and registers those inputs as DuckDB `ANY`. The result
can be a data frame, a named list of columns, or `rducks_table_stream()`
for scan-time batches. Finite results are imported once during bind;
stream results import batches as DuckDB scans.

``` r
rows_table <- rducks_register_table(
  con,
  name = "r_rows",
  fun = function(n) data.frame(i = seq_len(as.integer(n))),
  chunk_size = 2L
)

dbGetQuery(con, "SELECT * FROM r_rows(3) ORDER BY i")
#>   i
#> 1 1
#> 2 2
#> 3 3

stream_rows_table <- rducks_register_table(
  con,
  name = "r_stream_rows",
  fun = function(n) {
    next_i <- 1L
    limit <- as.integer(n)
    rducks_table_stream(
      prototype = data.frame(i = integer()),
      next_batch = function(batch_size) {
        if (next_i > limit) return(NULL)
        hi <- min(limit, next_i + as.integer(batch_size) - 1L)
        out <- data.frame(i = seq.int(next_i, hi))
        next_i <<- hi + 1L
        out
      }
    )
  },
  chunk_size = 2L
)

dbGetQuery(con, "SELECT sum(i) AS total FROM r_stream_rows(5)")
#>   total
#> 1    15
```

### Query streams

`rducks_query_stream()` is for R callers that want explicit
DuckDB-native query batches instead of an eager `DBI::dbGetQuery()`
result. The stream fetches native DuckDB chunks and imports them through
Arrow C Data/nanoarrow. `next_batch()` returns data frames by default;
`format = "record_batch"` returns an owned nanoarrow record batch so
materialization can happen later.

``` r
stream <- rducks_query_stream(
  con,
  "SELECT i::INTEGER AS i FROM range(1, 6) t(i)",
  batch_size = 2L
)
stream$next_batch()
#>   i
#> 1 1
#> 2 2
stream$next_batch()
#>   i
#> 1 3
#> 2 4
stream$close()

record_stream <- rducks_query_stream(
  con,
  "SELECT i::INTEGER AS i FROM range(1, 4) t(i)",
  batch_size = 2L,
  format = "record_batch"
)
record_batch <- record_stream$next_batch()
class(record_batch)
#> [1] "nanoarrow_array"
record_stream$close()
```

## Execution plans

Execution plans are fixed at scalar-UDF registration time.

| Plan                                | Scalar mode | Vectorized mode | Notes                                                                    |
|-------------------------------------|-------------|-----------------|--------------------------------------------------------------------------|
| `arrow_r + serial`                  | yes         | yes             | reference path using DuckDB Arrow C Data plus nanoarrow/R                |
| `arrow_r + inproc_concurrent`       | yes         | yes             | DuckDB workers enqueue callbacks; R work drains on the recorded R thread |
| `arrow_c + serial`                  | yes         | yes             | direct native DuckDB-vector materialization for supported types          |
| `arrow_c + inproc_concurrent`       | yes         | yes             | native materialization plus same-process queueing                        |
| `arrow_ipc + multiprocess_parallel` | yes         | yes             | native NNG plus owned Arrow IPC request/result bytes and R workers       |

The benchmark below registers the same sleeping vectorized UDF on three
real plans and runs the queries against one typed CSV scan with many
DuckDB-sized vectors. A padded column makes the single CSV large enough
for DuckDB’s parallel CSV scanner to split; the UDF still operates on
the integer column. The UDF closes over a random R lookup vector; the
Arrow IPC registration sends that global explicitly using
[`ipc_globals_share = "mori"`](https://shikokuchuo.net/mori/). Timings
are illustrative and machine-dependent, but the code exercises the
actual `arrow_r`, `arrow_c`, and native NNG/Arrow IPC paths. Use
`rducks_ipc_workers(con, ping = TRUE)` while an Arrow IPC plan is active
to list the managed NNG workers.

``` r
set.seed(1)
lookup <- sample.int(20L, 1000L, replace = TRUE)
slow_lookup <- function(x) {
  Sys.sleep(0.1)
  x + lookup[[1L]]
}

duckdb_vector_size <- 2048L
csv_rows <- duckdb_vector_size * 64L
csv_pad <- strrep("x", 128L)
csv_path <- tempfile("rducks-readme-csv-", fileext = ".csv")
writeLines(
  c("i,pad", paste0(seq.int(0L, csv_rows - 1L), ",", csv_pad)),
  csv_path
)

ipc_workers <- 2L
plans <- list(
  arrow_r = rducks_execution_plan("arrow_r", "serial"),
  arrow_c = rducks_execution_plan("arrow_c", "serial"),
  arrow_ipc_mori = rducks_execution_plan(
    "arrow_ipc", "multiprocess_parallel",
    ipc_workers = ipc_workers,
    ipc_transport = "ipc",
    ipc_timeout = 60,
    ipc_globals = "lookup",
    ipc_globals_share = "mori"
  )
)
udfs <- paste0("r_bench_", names(plans))

for (i in seq_along(plans)) {
  rducks_set_execution_plan(con, plans[[i]], threads = 1, external_threads = 1)
  rducks_register_scalar_udf(
    con,
    name = udfs[[i]],
    fun = slow_lookup,
    args = INTEGER,
    returns = INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  )
}

run_plan <- function(label, udf, plan, threads, external_threads) {
  rducks_set_execution_plan(
    con,
    plan,
    threads = threads,
    external_threads = external_threads
  )
  elapsed <- system.time({
    result <- DBI::dbGetQuery(con, sprintf(
      paste(
        "SELECT sum(%s((i %% 1000)::INTEGER)) AS total",
        "FROM read_csv(%s, header = true,",
        "columns = {'i': 'INTEGER', 'pad': 'VARCHAR'}, parallel = true)"
      ),
      DBI::dbQuoteIdentifier(con, udf),
      DBI::dbQuoteString(con, csv_path)
    ))
  })[["elapsed"]]
  data.frame(
    label = label,
    total = result$total[[1]],
    elapsed_sec = round(elapsed, 3)
  )
}

benchmark <- rbind(
  run_plan(
    "arrow_r serial", udfs[[1]], plans[[1]],
    threads = 1,
    external_threads = 1
  ),
  run_plan(
    "arrow_c serial", udfs[[2]], plans[[2]],
    threads = 1,
    external_threads = 1
  ),
  run_plan(
    "arrow_ipc + mori", udfs[[3]], plans[[3]],
    threads = ipc_workers + 1L,
    external_threads = ipc_workers
  )
)
unlink(csv_path, force = TRUE)
rducks_set_execution_plan(
  con,
  rducks_execution_plan("arrow_r", "serial"),
  threads = 1,
  external_threads = 1
)
benchmark
#>              label    total elapsed_sec
#> 1   arrow_r serial 65961344      10.278
#> 2   arrow_c serial 65961344      10.183
#> 3 arrow_ipc + mori 65961344       5.963
```

## duckplyr integration

`rducks_with_duckplyr()` and the `with.duckdb_connection()` method let
ordinary R calls inside duckplyr expressions resolve to Rducks scalar
UDFs, without writing `dd$...` calls. The fallback-blocking
demonstration lives in `inst/examples/no_fallback_duckplyr.R`; the
README keeps the shape minimal.

``` r
demo_con <- DBI::dbConnect(
  duckdb::duckdb(config = list(allow_unsigned_extensions = "true")),
  dbdir = ":memory:"
)
Rducks::rducks_enable(demo_con, threads = "single")
DBI::dbWriteTable(demo_con, "scores", data.frame(
  id = 1:3,
  x = c(2, 21, 34),
  label = c("low", "high", "high")
))

scores <- duckplyr::read_sql_duckdb(
  "SELECT * FROM scores",
  con = demo_con,
  prudence = "stingy"
)
local_score <- function(x, label) {
  as.double(x + if (identical(label, "high")) 100 else 0)
}

with(
  demo_con,
  scores |>
    dplyr::mutate(score = local_score(x, label)) |>
    dplyr::select(id, score) |>
    dplyr::collect(),
  rducks_returns = list(local_score = DOUBLE)
)
#> # A tibble: 3 × 2
#>      id score
#> * <int> <dbl>
#> 1     1     2
#> 2     2   121
#> 3     3   134

Rducks::rducks_release(demo_con)
DBI::dbDisconnect(demo_con, shutdown = TRUE)
```

## Arrow conversion options

`rducks_enable()` sets `arrow_lossless_conversion=true` on the user
connection, and the extension sets the same option on its internal
DuckDB connections. That is required for Rducks’ typed boundary:
DuckDB-specific logical types such as `UUID`, `HUGEINT`, `UHUGEINT`,
`INTERVAL`, `BIT`, and enums must keep their type metadata when chunks
cross DuckDB Arrow C Data. Without that setting, Arrow conversion can
erase type identity and dynamic omitted-`args` calls would no longer be
equivalent to explicit descriptors.

## Build notes

The source and vendored native dependencies used by `configure` live
under `tools/ext/`. During source-package installation, `configure`
writes the generated artifact to
`inst/rducks_extension/build/rducks.duckdb_extension` in the build tree;
after installation the runtime path is
`rducks_extension/build/rducks.duckdb_extension` inside the installed
package. `cleanup` removes only the generated artifact, not the source
tree needed by `R CMD build`. This package-bundled extension layout
follows precedents such as
[Rduckhts](https://github.com/RGenomicsETL/duckhts/tree/main/r/Rduckhts).
DuckDB C API headers are refreshed explicitly when the supported DuckDB
version changes.

``` sh
Rscript tools/fetch_duckdb_headers.R --ref v1.5.2
```

The extension uses DuckDB’s [C extension
API](https://github.com/duckdb/duckdb/blob/main/src/include/duckdb/main/capi/header_generation/README.md)
and unstable C extension ABI for Arrow conversion, connection/runtime
access, scalar-function bind/init hooks, dynamic bind-time argument
inspection, and selection-vector helpers. This table is generated from
`tools/used_duckdb_unstable_api.R` when `README.Rmd` is rendered:

| ABI group                                      | Functions used                                                                                                                                                                                                                                                                                                                                           | Count |
|------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------:|
| `unstable_deprecated`                          | `duckdb_pending_prepared_streaming`, `duckdb_result_is_streaming`, `duckdb_stream_fetch_chunk`                                                                                                                                                                                                                                                           |     3 |
| `unstable_new_arrow_functions`                 | `duckdb_data_chunk_from_arrow`, `duckdb_data_chunk_to_arrow`, `duckdb_destroy_arrow_converted_schema`, `duckdb_schema_from_arrow`, `duckdb_to_arrow_schema`                                                                                                                                                                                              |     5 |
| `unstable_new_error_data_functions`            | `duckdb_destroy_error_data`, `duckdb_error_data_has_error`, `duckdb_error_data_message`                                                                                                                                                                                                                                                                  |     3 |
| `unstable_new_expression_functions`            | `duckdb_destroy_expression`, `duckdb_expression_return_type`                                                                                                                                                                                                                                                                                             |     2 |
| `unstable_new_open_connect_functions`          | `duckdb_client_context_get_connection_id`, `duckdb_connection_get_arrow_options`, `duckdb_destroy_arrow_options`, `duckdb_destroy_client_context`                                                                                                                                                                                                        |     4 |
| `unstable_new_scalar_function_functions`       | `duckdb_scalar_function_bind_get_argument`, `duckdb_scalar_function_bind_get_argument_count`, `duckdb_scalar_function_bind_get_extra_info`, `duckdb_scalar_function_bind_set_error`, `duckdb_scalar_function_get_client_context`, `duckdb_scalar_function_set_bind`, `duckdb_scalar_function_set_bind_data`, `duckdb_scalar_function_set_bind_data_copy` |     8 |
| `unstable_new_scalar_function_state_functions` | `duckdb_scalar_function_get_state`, `duckdb_scalar_function_init_get_bind_data`, `duckdb_scalar_function_init_get_client_context`, `duckdb_scalar_function_init_get_extra_info`, `duckdb_scalar_function_init_set_error`, `duckdb_scalar_function_init_set_state`, `duckdb_scalar_function_set_init`                                                     |     7 |
| `unstable_new_string_functions`                | `duckdb_value_to_string`                                                                                                                                                                                                                                                                                                                                 |     1 |
| `unstable_new_value_functions`                 | `duckdb_get_time_ns`                                                                                                                                                                                                                                                                                                                                     |     1 |
| `unstable_new_vector_functions`                | `duckdb_create_selection_vector`, `duckdb_destroy_selection_vector`, `duckdb_selection_vector_get_data_ptr`, `duckdb_vector_copy_sel`                                                                                                                                                                                                                    |     4 |

See `docs/BUILD.md` for the build and ABI details.

## References

- [DuckDB extension
  overview](https://duckdb.org/docs/stable/extensions/overview)
- [DuckDB C extension API
  notes](https://github.com/duckdb/duckdb/blob/main/src/include/duckdb/main/capi/header_generation/README.md)
- [Apache Arrow nanoarrow for
  R](https://arrow.apache.org/nanoarrow/latest/r/)
- [NNG C library](https://nng.nanomsg.org/)
- [nanonext and mirai](https://mirai.r-lib.org/)
- [mori shared objects for R](https://shikokuchuo.net/mori/)
- [DuckDB Quack extension](https://github.com/duckdb/duckdb-quack)
- [Rduckhts bundled-extension
  precedent](https://github.com/RGenomicsETL/duckhts/tree/main/r/Rduckhts)
