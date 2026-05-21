# BIT logical operations

BIT logical operations

## Usage

``` r
# S3 method for class 'rducks_bits'
Ops(e1, e2)

rducks_bits_xor(e1, e2)
```

## Arguments

- e1, e2:

  `rducks_bits` values, raw bytes, or 0/1 vectors.

## Value

`rducks_bits` for bitwise operations or logical values for equality.

## Examples

``` r
a <- rducks_bits("1010")
b <- rducks_bits("1100")
as.character(a & b)
#> [1] "1000"
as.character(a | b)
#> [1] "1110"
as.character(rducks_bits_xor(a, b))
#> [1] "0110"
a == b
#> [1] FALSE
```
