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

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
rducks_enable(db)
rducks_register_scalar_udf(db, "my_fn", function(x) x + 1L,
  args = list(INTEGER), returns = INTEGER)
#> Error: Rducks R-backed functions require DuckDB to execute R code on the calling R thread; call rducks_enable(con, threads = 'single') or set external_threads=1 and PRAGMA threads=1 before registering R-backed functions
rducks_reset_udf_counters(db, "my_fn")
#> Error in duckdb_result(connection = conn, stmt_lst = stmt_lst, arrow = arrow): Invalid Error: Invalid Input Error: unknown Rducks UDF: my_fn
#> ℹ Context: rapi_execute
#> ℹ Error type: INVALID
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
