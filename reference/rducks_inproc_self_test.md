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
if (FALSE) { # \dontrun{
# Requires RDUCKS_DEV_SURFACES=true set before rducks_enable()
db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
rducks_enable(db)
rducks_inproc_self_test(db, n = 10L)
rducks_release(db)
DBI::dbDisconnect(db)
} # }
```
