# Construct DuckDB BIT values

`rducks_bits()` stores bits as packed raw bytes plus an explicit bit
length. Bits are packed left-to-right, with the first bit in the high
bit of the first byte.

## Usage

``` r
rducks_bits(x = raw(), length = NULL)

rducks_bits_raw(x)
```

## Arguments

- x:

  Character string of `0`/`1`, logical/integer bit vector, raw bytes, or
  another `rducks_bits` object.

- length:

  Optional bit length when `x` is raw.

## Value

Object of class `rducks_bits`.
