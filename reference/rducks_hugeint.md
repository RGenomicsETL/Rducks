# Construct exact DuckDB HUGEINT values

Values are stored as canonical decimal strings so values outside R's
exact numeric range are not silently rounded.

## Usage

``` r
rducks_hugeint(x = character())
```

## Arguments

- x:

  Numeric, integer, or character vector of whole numbers.

## Value

Character vector with class `rducks_hugeint`.

## Examples

``` r
rducks_hugeint(1:3)
#> <rducks_hugeint[3]>
#> [1] 1 2 3
rducks_hugeint("170141183460469231731687303715884105727")
#> <rducks_hugeint[1]>
#> [1] 170141183460469231731687303715884105727
```
