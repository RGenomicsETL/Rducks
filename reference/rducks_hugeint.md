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
