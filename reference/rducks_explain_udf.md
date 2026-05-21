# Explain a registered Rducks scalar UDF

Returns the R-side registration metadata together with native execution
counters for a DuckDB scalar UDF registered by
[`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md).
The `mode` column is the Rducks scalar-UDF evaluation mode, while
`plan_id`, `marshalling`, and `concurrency` describe the plan recorded
at registration time. The `r_side_record` column is `FALSE` when native
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

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
rducks_enable(db)
rducks_register_scalar_udf(db, "my_fn", function(x) x + 1L,
  args = list(INTEGER), returns = INTEGER)
#> Error: Rducks R-backed functions require DuckDB to execute R code on the calling R thread; call rducks_enable(con, threads = 'single') or set external_threads=1 and PRAGMA threads=1 before registering R-backed functions
rducks_explain_udf(db, "my_fn")
#> Error in duckdb_result(connection = conn, stmt_lst = stmt_lst, arrow = arrow): Invalid Error: Invalid Input Error: unknown Rducks UDF: my_fn
#> ℹ Context: rapi_execute
#> ℹ Error type: INVALID
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
