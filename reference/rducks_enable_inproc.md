# Enable in-process queued scalar execution

Switches a Rducks-enabled DuckDB connection to the in-process queued
scalar backend. This backend preserves R's thread discipline: DuckDB
worker-side UDF callbacks submit chunk requests to an extension-owned
queue, and the recorded main R execution lane drains the queue and
performs all R API work. This is a same-process scheduling mode, not a
performance promise; R function calls are still serialized on the main R
thread. The queued backend dispatches both scalar evaluator
implementations, `eval_mode = "R"` and `eval_mode = "RC"`, through that
same main-lane execution rule.

## Usage

``` r
rducks_enable_inproc(con, threads = NULL, external_threads = threads)
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
  enabling the in-process backend. Defaults to `threads`; use `NULL` to
  leave unchanged.

## Value

`con`, invisibly.

## Details

Register scalar UDFs while the connection is in the registration-safe
configuration, then call `rducks_enable_inproc()` before running queries
that should use the queued in-process path. Use
`threads`/`external_threads` here to adjust DuckDB's thread settings for
queued execution.
