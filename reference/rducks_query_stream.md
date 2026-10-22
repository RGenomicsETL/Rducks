# Stream a DuckDB query as native data-frame batches

Opens a native DuckDB streaming result through the Rducks extension and
returns the rows in DuckDB-sized batches as data frames, instead of an
eager
[`DBI::dbGetQuery()`](https://dbi.r-dbi.org/reference/dbGetQuery.html)
result. Each batch is materialized directly from DuckDB vectors to R
values on the recorded R thread. The stream uses the extension's
database-scoped connection, so it cannot see caller-connection temporary
tables or views, uncommitted transactions, or connection-local settings.

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
stream closes at end of input, on `$close()`, on native query error,
when its handle is garbage-collected, or when
[`rducks_release()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_release.md)
drops the last runtime anchor. Explicit `$close()` releases resources
promptly after early exit.

## Details

With `rducks_execution_plan("inproc")`, one persistent native driver
prepares, executes, fetches, and closes the query while the recorded R
thread services scalar callbacks. Requests keep their original task
identity and result destination; no source-row ordering is promised. R
table and aggregate callbacks are unsupported in this managed mode and
fail before off-thread R access. This mode requires a duckdb-r build
exposing version 2 of its off-main R-source guard and scheduler-lease
capability; ordinary builds without that capability fail with an
explicit error. Serial and IPC plans retain their synchronous execution
paths. Only one stream can be open for a database runtime at a time.
Recursive stream operations, release, and plan changes during callbacks
are rejected. While a managed stream is open, native configuration
guards also reject direct SQL changes to `threads` (including aliases),
`external_threads`, and the guard's configuration controls on every
connection to the database. The original configuration restrictions are
restored after the native driver has stopped. Close the stream before
changing those settings.

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#> duckdb keeps downloaded extensions and secrets in a temporary directory:
#> ℹ /tmp/RtmpHWria6/duckdb
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
