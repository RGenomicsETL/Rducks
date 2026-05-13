# Explain a registered Rducks scalar UDF

Returns the R-side registration metadata together with native execution
counters for a DuckDB scalar UDF registered by
[`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md).
The `mode` column is the Rducks scalar-UDF evaluation mode, while
`plan_id`, `marshalling`, and `concurrency` describe the frozen
execution plan. The `r_side_record` column is `FALSE` when native
catalog metadata is still present but the connection-local R registry
view was detached or is otherwise unavailable. The native counters are
useful for checking that a plan executed through its requested evaluator
instead of silently switching engines: for example, an `arrow_c` scalar
UDF should increment `arrow_c_chunks` and leave `arrow_r_chunks`
unchanged.

## Usage

``` r
rducks_explain_udf(con, name)
```

## Arguments

- con:

  A `duckdb_connection` with Rducks enabled.

- name:

  SQL scalar-UDF function name registered with
  [`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md).

## Value

A one-row data frame with scalar-UDF registration metadata and native
counters.
