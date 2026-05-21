# Inspect preserved-object release counters

Returns process-local diagnostics for preserved R objects that native
DuckDB catalog metadata could not release immediately because
destruction happened off the recorded main R thread. Safe main-thread
drain points include
[`rducks_enable()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable.md),
[`rducks_release()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_release.md),
[`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md),
scalar-UDF execution, and metadata/stat queries.

## Usage

``` r
rducks_release_stats(con)
```

## Arguments

- con:

  A `duckdb_connection`.

## Value

A one-row data frame with queued, released, failed, and pending
counters.

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb())
rducks_enable(db)
#> Error in duckdb_result(connection = conn, stmt_lst = stmt_lst, arrow = arrow): Invalid Error: IO Error: Extension "/home/runner/work/_temp/Library/Rducks/rducks_extension/build/rducks.duckdb_extension" could not be loaded because its signature is either missing or invalid and unsigned extensions are disabled by configuration (allow_unsigned_extensions)
#> ℹ Context: rapi_execute
#> ℹ Error type: INVALID
rducks_release_stats(db)
#> Error in dbSendQuery(conn, statement, ...): Catalog Error: Scalar Function with name rducks_release_queue_queued does not exist!
#> Did you mean "ucase"?
#> 
#> LINE 1: SELECT rducks_release_queue_queued() AS queued, rducks_release_que...
#>                ^
#> ℹ Context: rapi_prepare
#> ℹ Error type: CATALOG
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
