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
db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
rducks_enable(db)
rducks_release_stats(db)
#>   queued released failed pending
#> 1      0        4      0       0
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
