# Inspect the current Rducks execution plan

Returns the R-side execution plan recorded for a DuckDB connection. If
no plan has been recorded yet, this returns the reference plan
`arrow_r + serial`.

## Usage

``` r
rducks_current_execution_plan(con)
```

## Arguments

- con:

  A `duckdb_connection`.

## Value

An object of class `rducks_execution_plan`.

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb())
rducks_enable(db)
#> Error in duckdb_result(connection = conn, stmt_lst = stmt_lst, arrow = arrow): Invalid Error: IO Error: Extension "/home/runner/work/_temp/Library/Rducks/rducks_extension/build/rducks.duckdb_extension" could not be loaded because its signature is either missing or invalid and unsigned extensions are disabled by configuration (allow_unsigned_extensions)
#> ℹ Context: rapi_execute
#> ℹ Error type: INVALID
rducks_current_execution_plan(db)
#> <rducks_execution_plan>
#>   plan_id:     arrow_r+serial
#>   engine_id:   arrow_r_serial
#>   marshalling: arrow_r
#>   concurrency: serial
#>   reference:   yes
#>   implemented: yes
#>   call shapes: scalar, vectorized
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
