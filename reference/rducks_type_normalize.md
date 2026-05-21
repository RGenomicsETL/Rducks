# Normalize an Rducks type token

Character input is limited to canonical scalar tokens such as `i32`,
`f64`, and `varchar`. Composite, DECIMAL, ENUM, and UNION types are
represented by constructed `rducks_type` descriptors rather than quoted
type strings.

## Usage

``` r
rducks_type_normalize(x)
```

## Arguments

- x:

  Character scalar type token or a `rducks_type` descriptor.

## Value

Canonical scalar token for character input, or the descriptor's wire
token for a `rducks_type`.

## Examples

``` r
rducks_type_normalize("i32")
#> [1] "i32"
rducks_type_normalize(INTEGER)
#> [1] "i32"
rducks_type_normalize(LIST(VARCHAR))
#> [1] "list<varchar>"
```
