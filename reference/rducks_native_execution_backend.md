# Inspect the native Rducks execution backend

Returns the backend currently recorded in the native database-scoped
runtime. This is a diagnostic cross-check for
[`rducks_current_execution_plan()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_current_execution_plan.md),
whose value is the R-side default plan for future registrations through
this connection.

## Usage

``` r
rducks_native_execution_backend(con)
```

## Arguments

- con:

  A `duckdb_connection` already enabled with
  [`rducks_enable()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_enable.md).

## Value

Character scalar backend name: `"single"`, `"concurrent_inproc"`, or
`"multiprocess_parallel"`.

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
rducks_enable(db)
rducks_native_execution_backend(db)
#> [1] "single"
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
