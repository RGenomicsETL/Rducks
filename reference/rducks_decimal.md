# Construct exact DuckDB DECIMAL values

Values are stored as fixed-point character data plus a declared width
and scale. This avoids silently rounding exact decimal values through R
double.

## Usage

``` r
rducks_decimal(x = character(), width, scale = 0L)
```

## Arguments

- x:

  Numeric, integer, or character vector of fixed-point decimal values.

- width:

  DuckDB decimal width, from 1 to 38.

- scale:

  DuckDB decimal scale, from 0 to `width`.

## Value

Object of class `rducks_decimal`.

## Examples

``` r
rducks_decimal(c(1.5, 2.25, NA), width = 10, scale = 2)
#> <rducks_decimal[3] DECIMAL(10, 2)>
#> [1] 1.50 2.25 <NA>
```
