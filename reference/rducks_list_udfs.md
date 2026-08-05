# List registered Rducks scalar UDFs

Returns one row per DuckDB scalar UDF registered through
[`rducks_register_scalar_udf()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_register_scalar_udf.md)
in the current DuckDB database runtime, including the same registration
metadata and native counters as
[`rducks_explain_udf()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_explain_udf.md).
This is an Rducks scalar-UDF registry view, not a complete DuckDB
catalog listing: aggregate functions, table functions, functions
registered by other extensions, and raw SQL functions are not included.
Because DuckDB's function catalog is database scoped, sibling DBI
connections to the same database runtime share this view.

## Usage

``` r
rducks_list_udfs(con)
```

## Arguments

- con:

  A `duckdb_connection` with Rducks enabled.

## Value

A data frame with one row per Rducks scalar UDF registered on `con`.

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#> duckdb keeps downloaded extensions and secrets in a temporary directory:
#> ℹ /tmp/RtmpY861Yl/duckdb
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
rducks_list_udfs(db)
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
