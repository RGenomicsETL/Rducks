# Exercise the in-process queue

Runs a native self-test that submits `n` requests from worker threads to
the extension-owned main-thread queue and drains them on the recorded
main R thread. This validates the queue/condition-variable path without
calling an R UDF. This diagnostic SQL surface is dev/test-only; set
`RDUCKS_DEV_SURFACES=true` before
[`rducks_enable()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_enable.md)
if you need it.

## Usage

``` r
rducks_inproc_self_test(con, n = 1000L)
```

## Arguments

- con:

  A `duckdb_connection`.

- n:

  Number of queue round trips to run.

## Value

Integer-like numeric scalar: number of requests completed.

## Examples

``` r
# \donttest{
# The diagnostic needs RDUCKS_DEV_SURFACES=true before rducks_enable().
old <- Sys.getenv("RDUCKS_DEV_SURFACES", unset = NA)
Sys.setenv(RDUCKS_DEV_SURFACES = "true")
db <- duckdb::dbConnect(duckdb::duckdb(config = rducks_duckdb_config(list(threads = "2"))))
#> duckdb keeps downloaded extensions and secrets in a temporary directory:
#> ℹ /tmp/RtmpPMckDH/duckdb
#> This is removed when the R session ends.
#> • Extensions are re-downloaded each session.
#> • Secrets are lost.
#> ℹ Run duckdb(shared_home = TRUE) (or create ~/.duckdb) to keep them (suitable for most users).
#> ℹ Run duckdb(shared_home = FALSE) to accept the temporary directory (and silence this message).
#> ℹ See ?duckdb_storage for details and alternatives.
rducks_enable(db)
rducks_inproc_self_test(db, n = 10L)
#> [1] 10
rducks_release(db)
DBI::dbDisconnect(db)
if (is.na(old)) Sys.unsetenv("RDUCKS_DEV_SURFACES") else Sys.setenv(RDUCKS_DEV_SURFACES = old)
# }
```
