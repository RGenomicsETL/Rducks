# Exercise the in-process queue

Runs a native self-test that submits `n` requests from worker threads to
the extension-owned main-thread queue and drains them on the recorded R
execution lane. This validates the queue/condition-variable path without
calling an R UDF.

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
