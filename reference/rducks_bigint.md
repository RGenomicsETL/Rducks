# Construct exact DuckDB BIGINT values

Values are stored as canonical decimal strings so signed 64-bit values
are not silently rounded through R double.

## Usage

``` r
rducks_bigint(x = character())
```

## Arguments

- x:

  Numeric, integer, or character vector of whole numbers.

## Value

Character vector with class `rducks_bigint`.
