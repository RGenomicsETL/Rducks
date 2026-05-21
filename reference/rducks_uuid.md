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

## Examples

``` r
rducks_uuid("550e8400-e29b-41d4-a716-446655440000")
#> <rducks_uuid[1]>
#> [1] 550e8400-e29b-41d4-a716-446655440000
```
