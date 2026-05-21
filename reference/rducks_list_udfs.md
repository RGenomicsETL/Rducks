# List registered Rducks scalar UDFs

Returns one row per DuckDB scalar UDF registered through
[`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md)
in the current DuckDB database runtime, including the same registration
metadata and native counters as
[`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md).
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
db <- duckdb::dbConnect(duckdb::duckdb())
rducks_enable(db)
#> Error in duckdb_result(connection = conn, stmt_lst = stmt_lst, arrow = arrow): Invalid Error: IO Error: Extension "/home/runner/work/_temp/Library/Rducks/rducks_extension/build/rducks.duckdb_extension" could not be loaded because its signature is either missing or invalid and unsigned extensions are disabled by configuration (allow_unsigned_extensions)
#> ℹ Context: rapi_execute
#> ℹ Error type: INVALID
rducks_register_scalar_udf(db, "my_fn", function(x) x + 1L,
  args = list(INTEGER), returns = INTEGER)
#> Error: Rducks R-backed functions require DuckDB to execute R code on the calling R thread; call rducks_enable(con, threads = 'single') or set external_threads=1 and PRAGMA threads=1 before registering R-backed functions
rducks_list_udfs(db)
#>  [1] name                              mode                             
#>  [3] plan_id                           engine_id                        
#>  [5] marshalling                       concurrency                      
#>  [7] native_marshalling                evaluator                        
#>  [9] args                              returns                          
#> [11] r_side_record                     null_handling                    
#> [13] exception_handling                side_effects                     
#> [15] dispatch_chunks                   dispatch_rows                    
#> [17] direct_chunks                     queued_chunks                    
#> [19] queue_pending_current             queue_pending_max                
#> [21] arrow_r_chunks                    arrow_c_chunks                   
#> [23] arrow_c_input_snapshot_chunks     arrow_c_owned_result_chunk_chunks
#> [25] arrow_ipc_chunks                  ripc_collect_batches             
#> [27] ripc_collect_requests             ripc_collect_max_batch           
#> [29] ripc_submit_wave_max              ripc_collect_ready_max           
#> [31] ripc_inflight_current             ripc_inflight_max                
#> <0 rows> (or 0-length row.names)
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
