# Reset Rducks UDF counters

Resets native per-UDF diagnostic counters without unregistering any
DuckDB catalog function. Current liveness gauges such as
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

  Optional SQL function name registered with
  [`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md).
  If `NULL`, reset counters for all native Rducks UDFs in the database
  runtime.

## Value

Invisibly `TRUE` on success.
