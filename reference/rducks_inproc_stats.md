# Inspect in-process queue counters

Returns diagnostic counters for the extension-owned in-process queue.
`submitted` counts requests submitted to the recorded main R thread,
`executed` counts requests drained by that thread, and `timeouts` counts
requests that were abandoned rather than waiting indefinitely. The
`pending_*` and `running_*` columns expose current and maximum queue
pressure: pending requests are waiting to be drained by the main R
thread, while running requests have been popped by that thread and are
executing or collecting.

## Usage

``` r
rducks_inproc_stats(con)
```

## Arguments

- con:

  A `duckdb_connection`.

## Value

A one-row data frame with queue diagnostic columns.
