# Construct DuckDB UNION values

`rducks_union()` represents one tagged union value. The tag should match
a DuckDB union member name; `value` is the corresponding R value.

## Usage

``` r
rducks_union(tag, value)
```

## Arguments

- tag:

  Character scalar union member name.

- value:

  R value for that member.

## Value

Object of class `rducks_union`.

## Examples

``` r
rducks_union("num", 42L)
#> <rducks_union tag=num>
#> [1] 42
rducks_union("str", "hello")
#> <rducks_union tag=str>
#> [1] "hello"
```
