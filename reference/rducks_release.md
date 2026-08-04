# Detach Rducks connection-local state

Detaches Rducks' connection-local R state for `con`. This clears the
current default execution plan and releases this connection's R-side
runtime anchor. It does not drop DuckDB catalog functions, unregister
scalar UDFs, or release native-owned R closures that are still
referenced by database-scoped catalog metadata. If sibling DBI
connections are attached to the same DuckDB database runtime, their
database-scoped Rducks registration metadata remains visible. For
file-backed databases, releasing the last attachment also closes Rducks'
extension-owned DuckDB connections, which lets the DuckDB file be closed
and reopened in the same R process on platforms with strict file
locking.

## Usage

``` r
rducks_release(con)

rducks_detach(con)
```

## Arguments

- con:

  A `duckdb_connection`.

## Value

`con`, invisibly.

## Details

Rducks deliberately keeps the plain `duckdb_connection` object and does
not override DBI's
[`dbDisconnect()`](https://dbi.r-dbi.org/reference/dbDisconnect.html)
method. Call `rducks_release(con)` explicitly before
`DBI::dbDisconnect(con)` when you want deterministic connection-local
Rducks cleanup; weak-reference finalizers provide only best-effort
cleanup if the connection object is garbage-collected.

Call
[`rducks_enable()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_enable.md)
again before using `con` for further Rducks registrations or
connection-local plan changes.

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#> duckdb keeps downloaded extensions and secrets in a temporary directory:
#> ℹ /tmp/RtmpwFko0t/duckdb
#> This is removed when the R session ends.
#> • Extensions are re-downloaded each session.
#> • Secrets are lost.
#> ℹ Run duckdb(shared_home = TRUE) (or create ~/.duckdb) to keep them (suitable for most users).
#> ℹ Run duckdb(shared_home = FALSE) to accept the temporary directory (and silence this message).
#> ℹ See ?duckdb_storage for details and alternatives.
rducks_enable(db)
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
