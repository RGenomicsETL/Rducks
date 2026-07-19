# Construct a DuckDB VARIANT storage object

`VARIANT` values cross the Rducks boundary as DuckDB's typed storage
object: a named list with `keys`, `children`, `values`, and `data`
fields. Most code receives this object from a VARIANT argument and
returns it unchanged or after using DuckDB SQL functions such as
`variant_extract()` before crossing into R. Validation covers field
types, child/key/value indexes, logical type ids, byte offsets, nested
child ranges, and fixed/variable payload bounds before storage can be
written back into a DuckDB vector.

## Usage

``` r
rducks_variant(x)
```

## Arguments

- x:

  Named list in DuckDB VARIANT storage shape.

## Value

`x` with class `rducks_variant` after validation.

## Examples

``` r
# VARIANT storage objects are normally produced by DuckDB at the R boundary.
# rducks_variant() validates the storage shape; constructing one by hand
# requires the full internal DuckDB VARIANT storage layout.
```
