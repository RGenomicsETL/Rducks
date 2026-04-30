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
