# Inspect in-process queue counters

Returns diagnostic counters for the extension-owned in-process queue.
`submitted` counts requests submitted to the recorded main R thread,
`executed` counts requests drained by that thread, and `timeouts` counts
requests that were abandoned rather than waiting indefinitely. The
`pending_*` and `running_*` columns expose current and maximum queue
pressure: pending requests are waiting to be drained by the main R
thread, while running requests have been popped by that thread and are
executing or collecting. `main_drains`, `main_drain_batches`, and
`main_drain_max_batch` count how often the recorded main R thread
attempted queue drains and how many queued requests were handled in
non-empty drain waves. `pending_timeout_ms` is the configured native
pending-request timeout. Running requests borrow DuckDB callback-frame
input/output storage, so running-timeout cancellation is intentionally
not supported and is reported via `running_timeout_supported = FALSE`.
This is a runtime queue summary; for per-scalar-UDF execution detail
such as selected evaluator and direct input/result counters, use
[`rducks_explain_udf()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_explain_udf.md).

## Usage

``` r
rducks_inproc_stats(con)
```

## Arguments

- con:

  A `duckdb_connection`.

## Value

A one-row data frame with queue diagnostic columns.

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
rducks_inproc_stats(db)
#>   submitted executed timeouts pending_current pending_max running_current
#> 1         0        0        0               0           0               0
#>   running_max main_drains main_drain_batches main_drain_max_batch
#> 1           0           0                  0                    0
#>   pending_timeout_ms running_timeout_supported
#> 1              30000                     FALSE
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
