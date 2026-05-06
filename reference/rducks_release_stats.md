# Inspect preserved-object release counters

Returns process-local diagnostics for preserved R objects that native
DuckDB catalog metadata could not release immediately because
destruction happened off the recorded main R thread. Safe main-thread
drain points include
[`rducks_enable()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable.md),
[`rducks_release()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_release.md),
[`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md),
UDF execution, and metadata/stat queries.

## Usage

``` r
rducks_release_stats(con)
```

## Arguments

- con:

  A `duckdb_connection`.

## Value

A one-row data frame with queued, released, failed, and pending
counters.
