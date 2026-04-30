# Construct DuckDB ENUM values

`rducks_enum()` stores values as a factor with an additional class so
the DuckDB enum dictionary is explicit.

## Usage

``` r
rducks_enum(x, levels = NULL)
```

## Arguments

- x:

  Character vector or factor of enum values.

- levels:

  Character vector of allowed enum dictionary values. If `x` is a factor
  and `levels` is omitted, the factor levels are used.

## Value

Factor with class `rducks_enum`.
