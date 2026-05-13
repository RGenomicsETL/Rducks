# Describe Rducks NULL, NA, NaN, and Inf semantics

`rducks_value_semantics()` is the package-level schema for DuckDB
scalar-UDF missing and non-finite value handling. It is intended to be
rendered directly in README and pkgdown documentation, and to keep the
documented NULL/NA/NaN/Inf contract close to the type descriptors used
by the marshaller.

## Usage

``` r
rducks_value_semantics(x = NULL)
```

## Arguments

- x:

  Optional scalar type tokens or constructed `rducks_type` descriptors.
  When `NULL`, all currently implemented DuckDB scalar-UDF scalar type
  semantics are returned. Constructed descriptors such as
  `DECIMAL(10, 2)`, `ENUM(c("a", "b"))`,
  `UNION(i = INTEGER, s = VARCHAR)`, `INTEGER[]`, `INTEGER[3]`,
  `STRUCT(a = INTEGER)`, and `MAP(VARCHAR, INTEGER)` can be requested
  explicitly.

## Value

A data frame with one row per requested type descriptor and columns
describing SQL NULL input handling, R missing/non-finite return
handling, Rducks value-class binary operation behavior, and error
semantics.

## Details

With `null_handling = "default"`, top-level SQL `NULL` inputs
short-circuit to SQL `NULL` and the R function is not called. The
`special_null_argument` column describes what the R function receives
with `null_handling = "special"`.

Return semantics are stated from R back to DuckDB. For DuckDB scalar
UDFs, top-level `NULL` returns map to SQL `NULL`; type-specific R `NA`
values also map to SQL `NULL` where a missing representation exists.
`NaN` and `Inf` are values only for `FLOAT` and `DOUBLE`; integer, date,
time, timestamp, and exact Rducks value classes reject non-finite
values.
