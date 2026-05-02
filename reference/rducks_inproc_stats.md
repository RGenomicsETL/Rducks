# Inspect in-process queue counters

Returns diagnostic counters for the extension-owned in-process queue.
`submitted` counts requests submitted to the main R execution lane,
`executed` counts requests drained by that lane, and `timeouts` counts
requests that were abandoned rather than waiting indefinitely.

## Usage

``` r
rducks_inproc_stats(con)
```

## Arguments

- con:

  A `duckdb_connection`.

## Value

A one-row data frame with columns `submitted`, `executed`, and
`timeouts`.
