# List registered Rducks UDFs

Returns one row per UDF registered through
[`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md)
on a connection, including the same registration metadata and native
counters as
[`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md).
This is an Rducks registry view, not a complete DuckDB catalog listing:
functions registered by other extensions or raw SQL are not included.

## Usage

``` r
rducks_list_udfs(con)
```

## Arguments

- con:

  A `duckdb_connection` with Rducks enabled.

## Value

A data frame with one row per Rducks UDF registered on `con`.
