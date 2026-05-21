# Convert Rducks type descriptors to DuckDB SQL types

Convert Rducks type descriptors to DuckDB SQL types

## Usage

``` r
rducks_duckdb_types(x)
```

## Arguments

- x:

  Character scalar tokens, `rducks_type` descriptors, or a list of
  descriptors.

## Value

Character vector of DuckDB SQL type names.

## Examples

``` r
rducks_duckdb_types(INTEGER)
#> [1] "INTEGER"
rducks_duckdb_types(c(INTEGER, DOUBLE, VARCHAR))
#> [1] "INTEGER" "DOUBLE"  "VARCHAR"
rducks_duckdb_types(STRUCT(a = INTEGER, b = VARCHAR))
#> [1] "STRUCT(a INTEGER, b VARCHAR)"
```
