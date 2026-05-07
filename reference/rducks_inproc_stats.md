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
This is a runtime queue summary; for per-UDF execution detail such as
selected evaluator, Arrow IPC waves, direct `arrow_c` input snapshots,
and owned result-chunk counters, use
[`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md).

## Usage

``` r
rducks_inproc_stats(con)
```

## Arguments

- con:

  A `duckdb_connection`.

## Value

A one-row data frame with queue diagnostic columns.
