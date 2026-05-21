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

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb())
rducks_enable(db)
#> Error in duckdb_result(connection = conn, stmt_lst = stmt_lst, arrow = arrow): Invalid Error: IO Error: Extension "/home/runner/work/_temp/Library/Rducks/rducks_extension/build/rducks.duckdb_extension" could not be loaded because its signature is either missing or invalid and unsigned extensions are disabled by configuration (allow_unsigned_extensions)
#> ℹ Context: rapi_execute
#> ℹ Error type: INVALID
rducks_native_execution_backend(db)
#> Error in dbSendQuery(conn, statement, ...): Catalog Error: Scalar Function with name rducks_execution_backend does not exist!
#> Did you mean "ucase"?
#> 
#> LINE 1: SELECT rducks_execution_backend() AS backend
#>                ^
#> ℹ Context: rapi_prepare
#> ℹ Error type: CATALOG
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
