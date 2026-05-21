# Construct exact DuckDB UBIGINT values

Values are stored as canonical unsigned decimal strings.

## Usage

``` r
rducks_ubigint(x = character())
```

## Arguments

- x:

  Numeric, integer, or character vector of whole unsigned numbers.

## Value

Character vector with class `rducks_ubigint`.

## Examples

``` r
rducks_ubigint(0:2)
#> <rducks_ubigint[3]>
#> [1] 0 1 2
rducks_ubigint("18446744073709551615")
#> <rducks_ubigint[1]>
#> [1] 18446744073709551615
```
