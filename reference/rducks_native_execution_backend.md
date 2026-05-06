# Inspect the native Rducks execution backend

Returns the backend currently recorded in the native database-scoped
runtime. This is a diagnostic cross-check for
[`rducks_current_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_current_execution_plan.md),
whose value is the R-side default plan for future registrations through
this connection.

## Usage

``` r
rducks_native_execution_backend(con)
```

## Arguments

- con:

  A `duckdb_connection` already enabled with
  [`rducks_enable()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable.md).

## Value

Character scalar backend name: `"single"`, `"concurrent_inproc"`, or
`"multiprocess_parallel"`.
