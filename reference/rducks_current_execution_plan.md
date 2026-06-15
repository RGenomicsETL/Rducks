# Inspect the current Rducks execution plan

Returns the R-side execution plan recorded for a DuckDB connection. If
no plan has been recorded yet, this returns the reference plan
`direct + serial`.

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
db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
rducks_enable(db)
rducks_current_execution_plan(db)
#> <rducks_execution_plan>
#>   plan_id:     direct+serial
#>   engine_id:   direct_serial
#>   transport:   inproc
#>   concurrency: serial
#>   reference:   yes
#>   implemented: yes
#>   call shapes: scalar, vectorized
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
