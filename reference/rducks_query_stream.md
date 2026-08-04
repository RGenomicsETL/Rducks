# Stream a DuckDB query as native data-frame batches

Opens a native DuckDB streaming result through the Rducks extension and
returns the rows in DuckDB-sized batches as data frames, instead of an
eager
[`DBI::dbGetQuery()`](https://dbi.r-dbi.org/reference/dbGetQuery.html)
result. Each batch is materialized directly from DuckDB vectors to R
values on the recorded R thread. The stream uses the extension's
database-scoped connection, so it cannot see caller-connection temporary
tables or views.

## Usage

``` r
rducks_query_stream(con, sql)
```

## Arguments

- con:

  A `duckdb_connection` with Rducks enabled.

- sql:

  A non-empty SQL query string.

## Value

An object of class `rducks_query_stream` with `$next_batch()` (returns
the next data-frame batch, or `NULL` at end of stream), `$close()`,
`$schema` (column names and Rducks type tokens), and `$token`. The
stream closes on `$close()` or `rducks_release(con)`.

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
stream <- rducks_query_stream(db, "SELECT i::INTEGER AS i FROM range(1, 6) t(i)")
stream$next_batch()
#>   i
#> 1 1
#> 2 2
#> 3 3
#> 4 4
#> 5 5
stream$close()
rducks_release(db)
DBI::dbDisconnect(db, shutdown = TRUE)
# }
```
