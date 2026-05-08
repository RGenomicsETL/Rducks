# Explain a registered Rducks UDF

Returns the R-side registration metadata together with native execution
counters for a UDF registered by
[`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md).
The `r_side_record` column is `FALSE` when native catalog metadata is
still present but the connection-local R registry view was detached or
is otherwise unavailable. The native counters are useful for checking
that a plan executed through its requested evaluator instead of silently
switching engines: for example, an `arrow_c` scalar UDF should increment
`arrow_c_chunks` and leave `arrow_r_chunks` unchanged.

## Usage

``` r
rducks_explain_udf(con, name)
```

## Arguments

- con:

  A `duckdb_connection` with Rducks enabled.

- name:

  SQL function name registered with
  [`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md).

## Value

A one-row data frame with registration metadata and native counters.
