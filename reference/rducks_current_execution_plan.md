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
