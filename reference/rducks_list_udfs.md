# List registered Rducks scalar UDFs

Returns one row per DuckDB scalar UDF registered through
[`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md)
in the current DuckDB database runtime, including the same registration
metadata and native counters as
[`rducks_explain_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_explain_udf.md).
This is an Rducks scalar-UDF registry view, not a complete DuckDB
catalog listing: aggregate functions, table functions, functions
registered by other extensions, and raw SQL functions are not included.
Because DuckDB's function catalog is database scoped, sibling DBI
connections to the same database runtime share this view.

## Usage

``` r
rducks_list_udfs(con)
```

## Arguments

- con:

  A `duckdb_connection` with Rducks enabled.

## Value

A data frame with one row per Rducks scalar UDF registered on `con`.
