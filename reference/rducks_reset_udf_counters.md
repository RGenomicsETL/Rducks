# Reset Rducks scalar-UDF counters

Resets native per-scalar-UDF diagnostic counters without unregistering
any DuckDB catalog function. Current liveness gauges such as
pending/in-flight counts are preserved; their max fields are reset to
the current values.

## Usage

``` r
rducks_reset_udf_counters(con, name = NULL)
```

## Arguments

- con:

  A `duckdb_connection` with Rducks enabled.

- name:

  Optional SQL scalar-UDF function name registered with
  [`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md).
  If `NULL`, reset counters for all native Rducks scalar UDFs in the
  database runtime.

## Value

Invisibly `TRUE` on success.
