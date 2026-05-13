# Enable in-process queued scalar-UDF execution

Switches a Rducks-enabled DuckDB connection to the in-process queued
scalar-UDF backend. This backend preserves R's thread discipline: DuckDB
worker-side scalar-UDF callbacks submit chunk requests to an
extension-owned queue, and the recorded main R thread drains the queue
and performs all R API work. This is a same-process scheduling mode, not
a performance promise; R function calls are still serialized on the main
R thread. This helper changes only the concurrency part of the active
execution plan; marshalling stays `arrow_r` or `arrow_c` according to
[`rducks_set_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_set_execution_plan.md).

## Usage

``` r
rducks_enable_inproc(con, threads = NULL, external_threads = NULL)
```

## Arguments

- con:

  A `duckdb_connection` already enabled with
  [`rducks_enable()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable.md).

- threads:

  Optional positive integer to set with `PRAGMA threads` before enabling
  the in-process backend. Use `NULL` to leave unchanged.

- external_threads:

  Optional positive integer to set with `SET external_threads` before
  enabling the in-process backend. Use `NULL` to leave unchanged. For
  actual DuckDB worker concurrency, keep this smaller than `threads`
  (for example `threads = 4, external_threads = 1`).

## Value

`con`, invisibly.

## Details

Register scalar UDFs while the connection is in the registration-safe
configuration, then call `rducks_enable_inproc()` before running queries
that should use the queued in-process path. Use
`threads`/`external_threads` here to adjust DuckDB's thread settings for
queued execution.
