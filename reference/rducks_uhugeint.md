# Construct exact DuckDB UHUGEINT values

Values are stored as canonical unsigned decimal strings.

## Usage

``` r
rducks_uhugeint(x = character())
```

## Arguments

- x:

  Numeric, integer, or character vector of whole unsigned numbers.

## Value

Character vector with class `rducks_uhugeint`.

## Examples

``` r
rducks_uhugeint(0:2)
#> <rducks_uhugeint[3]>
#> [1] 0 1 2
rducks_uhugeint("340282366920938463463374607431768211455")
#> <rducks_uhugeint[1]>
#> [1] 340282366920938463463374607431768211455
```
