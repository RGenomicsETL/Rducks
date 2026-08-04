# Explain a registered Rducks scalar UDF

Returns the R-side registration metadata together with native execution
counters for a DuckDB scalar UDF registered by
[`rducks_register_scalar_udf()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_register_scalar_udf.md).
The `mode` column is the Rducks scalar-UDF evaluation mode, while
`plan_id`, `marshalling`, and `concurrency` describe the plan recorded
at registration time. The `r_side_record` column is `FALSE` when native
catalog metadata is still present but the connection-local R registry
view was detached or is otherwise unavailable. The native counters are
useful for checking that a plan executed through its requested evaluator
instead of silently switching engines: for example, a direct scalar UDF
should increment `direct_eval_chunks` and leave `wire_chunks` unchanged.

## Usage

``` r
rducks_explain_udf(con, name)
```

## Arguments

- con:

  A `duckdb_connection` with Rducks enabled.

- name:

  SQL scalar-UDF function name registered with
  [`rducks_register_scalar_udf()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_register_scalar_udf.md).

## Value

A one-row data frame with scalar-UDF registration metadata and native
counters.

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#> duckdb keeps downloaded extensions and secrets in a temporary directory:
#> ℹ /tmp/RtmpuLcEWY/duckdb
#> This is removed when the R session ends.
#> • Extensions are re-downloaded each session.
#> • Secrets are lost.
#> ℹ Run duckdb(shared_home = TRUE) (or create ~/.duckdb) to keep them (suitable for most users).
#> ℹ Run duckdb(shared_home = FALSE) to accept the temporary directory (and silence this message).
#> ℹ See ?duckdb_storage for details and alternatives.
rducks_enable(db, threads = "single")
rducks_register_scalar_udf(db, "my_fn", function(x) x + 1L,
  args = list(INTEGER), returns = INTEGER)
#> <rducks_scalar_udf_registration>
#>   registered:      yes
#>   name:            my_fn
#>   evaluation_mode: scalar
#>   plan:            direct+serial
#>   signature:       my_fn(INTEGER) -> INTEGER
rducks_explain_udf(db, "my_fn")
#>    name   mode       plan_id     engine_id marshalling concurrency
#> 1 my_fn scalar direct+serial direct_serial      direct      serial
#>   native_marshalling evaluator args returns r_side_record null_handling
#> 1             direct        RC  i32     i32          TRUE       default
#>   exception_handling side_effects dispatch_chunks dispatch_rows direct_chunks
#> 1            rethrow        FALSE               0             0             0
#>   queued_chunks queue_pending_current queue_pending_max sexp_chunks
#> 1             0                     0                 0           0
#>   direct_eval_chunks direct_input_snapshot_chunks
#> 1                  0                            0
#>   direct_owned_result_chunk_chunks wire_chunks ripc_collect_batches
#> 1                                0           0                    0
#>   ripc_collect_requests ripc_collect_max_batch ripc_submit_wave_max
#> 1                     0                      0                    0
#>   ripc_collect_ready_max ripc_inflight_current ripc_inflight_max
#> 1                      0                     0                 0
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
