
<!-- README.md is generated from README.Rmd. Please edit README.Rmd. -->

# Rducks

[![R-CMD-check](https://github.com/sounkou-bioinfo/Rducks/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/sounkou-bioinfo/Rducks/actions/workflows/R-CMD-check.yaml)
[![R-universe](https://sounkou-bioinfo.r-universe.dev/badges/Rducks)](https://sounkou-bioinfo.r-universe.dev/Rducks)

Rducks registers R functions as DuckDB SQL functions through a
package-managed DuckDB C extension. It is built around explicit type
descriptors, DuckDB Arrow C Data/nanoarrow marshalling, and a strict
rule that R object work runs on the recorded R thread unless it is
intentionally moved to R worker processes through the Arrow IPC plan.

The public surface is split by role:

- scalar UDFs: `rducks_register_scalar_udf()`;
- aggregate functions: `rducks_register_aggregate()`;
- table functions: `rducks_register_table()`;
- R-side query streaming: `rducks_query_stream()`.

Scalar UDFs also choose an evaluation mode (`"scalar"` or
`"vectorized"`) and an execution plan (`arrow_r`, `arrow_c`, or
`arrow_ipc`). Aggregates, table functions, and query streams are
separate APIs rather than scalar-UDF plan variants.

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
  fun = function(x, label) {
    bonus <- if (identical(label, "high")) 100 else 0
    as.double(x + bonus)
  },
  returns = DOUBLE,
  side_effects = TRUE
)

dbGetQuery(con, "
  SELECT r_score(x::DOUBLE, label) AS score
  FROM (VALUES (2, 'low'), (21, 'high')) AS t(x, label)
")
#>   score
#> 1     2
#> 2   121
```

`r_score()` omits `args`, so DuckDB registers it as a dynamic varargs
scalar UDF. The return type is still explicit. At each SQL call site,
DuckDB binds the concrete argument types and Rducks then materializes
those inputs as if the signature had been declared with `args = ...`.
Use `args = NULL` only for a true zero-argument UDF.

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
rducks_type_sql(nested_type)
#> [1] "STRUCT(id INTEGER, label ENUM('low', 'high'), payload UNION(code INTEGER, note VARCHAR), values DECIMAL(10, 2)[])"
rducks_type_child_names(nested_type)
#> [1] "id"      "label"   "payload" "values"
```

## Scalar UDFs

Scalar mode calls the R function once per logical row. Vectorized mode
calls the R function once per DuckDB chunk with one R vector or
list-column per declared or dynamically bound argument.

``` r
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

dbGetQuery(con, sprintf("\n  SELECT\n    r_nested_declared(%1$s) AS declared,\n    r_nested_dynamic(%1$s) AS dynamic\n", nested_sql))
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
rducks_argument_type_mapping(list(INTEGER, UUID, DECIMAL(10, 2), STRUCT(a = INTEGER[])))[,
  c("duckdb_type", "r_value_class", "special_null_argument")
]
#>           duckdb_type  r_value_class special_null_argument
#> 1             INTEGER        integer           NA_integer_
#> 2                UUID    rducks_uuid                  NULL
#> 3      DECIMAL(10, 2) rducks_decimal                  NULL
#> 4 STRUCT(a INTEGER[])           list                  NULL
```

## Aggregates, table functions, and query streams

Aggregates keep preserved R state owned by the extension and execute on
the recorded R thread.

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

dbGetQuery(con, "SELECT r_sum_i32(i) AS total FROM (VALUES (1::INTEGER), (2::INTEGER), (NULL::INTEGER)) t(i)")
#>   total
#> 1     3
```

Table functions return a data frame, a named list of columns, or an
`rducks_table_stream()` for scan-time batches.

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
```

Use `rducks_query_stream()` when an R caller wants explicit
DuckDB-native query batches instead of an eager `DBI::dbGetQuery()`
result.

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

``` r
arrow_c_plan <- rducks_set_execution_plan(
  con,
  rducks_execution_plan("arrow_c", "serial"),
  threads = 1,
  external_threads = 1
)

arrow_c_plus_one_udf <- rducks_register_scalar_udf(
  con,
  name = "r_arrow_c_plus_one",
  fun = function(x) x + 1,
  args = INTEGER,
  returns = INTEGER,
  mode = "vectorized",
  side_effects = TRUE
)

dbGetQuery(con, "SELECT sum(r_arrow_c_plus_one(i::INTEGER)) AS total FROM range(5) AS t(i)")
#>   total
#> 1    15
rducks_explain_udf(con, "r_arrow_c_plus_one")[, c("name", "mode", "plan_id", "evaluator")]
#>                 name       mode        plan_id evaluator
#> 1 r_arrow_c_plus_one vectorized arrow_c+serial       RCV

serial_plan <- rducks_set_execution_plan(con, rducks_execution_plan("arrow_r", "serial"), threads = 1, external_threads = 1)
```

For process isolation, choose the Arrow IPC plan. Local providers are
launched as mirai workers and communicate with the extension over
generated NNG endpoints. Explicit `ipc_globals`, `ipc_packages`, and
`ipc_globals_share = "mori"` are available when worker functions need
external R objects.

``` r
ipc_plan <- rducks_execution_plan(
  "arrow_ipc", "multiprocess_parallel",
  ipc_workers = 1L,
  ipc_transport = "tcp",
  ipc_timeout = 30
)
ipc_plan_active <- rducks_set_execution_plan(con, ipc_plan, threads = 1, external_threads = 1)

ipc_plus_one_udf <- rducks_register_scalar_udf(
  con,
  name = "r_ipc_plus_one",
  fun = function(x) x + 1L,
  args = INTEGER,
  returns = INTEGER,
  mode = "vectorized",
  side_effects = TRUE
)

dbGetQuery(con, "SELECT sum(r_ipc_plus_one(i::INTEGER)) AS total FROM range(10) AS t(i)")
#>   total
#> 1    55
rducks_explain_udf(con, "r_ipc_plus_one")[, c("plan_id", "evaluator", "arrow_ipc_chunks", "ripc_inflight_max")]
#>                           plan_id evaluator arrow_ipc_chunks ripc_inflight_max
#> 1 arrow_ipc+multiprocess_parallel      RIPC                1                 1

serial_plan <- rducks_set_execution_plan(con, rducks_execution_plan("arrow_r", "serial"), threads = 1, external_threads = 1)
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

scores <- duckplyr::read_sql_duckdb("SELECT * FROM scores", con = demo_con, prudence = "stingy")
local_score <- function(x, label) as.double(x + if (identical(label, "high")) 100 else 0)

out <- with(
  demo_con,
  scores |>
    dplyr::mutate(score = local_score(x, label)) |>
    dplyr::select(id, score) |>
    dplyr::collect(),
  rducks_returns = list(local_score = DOUBLE)
)
out
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
tree needed by `R CMD build`. DuckDB C API headers are refreshed
explicitly when the supported DuckDB version changes.

``` sh
Rscript tools/fetch_duckdb_headers.R --ref v1.5.2
```

The extension uses DuckDB’s unstable C extension ABI for Arrow
conversion, connection/runtime access, scalar-function bind/init hooks,
dynamic bind-time argument inspection, and selection-vector helpers. The
current detected surface is:

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

`tools/used_duckdb_unstable_api.R` regenerates this table. See
`docs/BUILD.md` for the build and ABI details.
