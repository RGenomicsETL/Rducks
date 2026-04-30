# Construct DuckDB UUID values

`rducks_uuid()` stores canonical UUID text in a dedicated class. Native
UDF marshalling for DuckDB `UUID` is implemented separately from this
value class.

## Usage

``` r
rducks_uuid(x = character())
```

## Arguments

- x:

  Character vector of UUID strings.

## Value

Character vector with class `rducks_uuid`.
