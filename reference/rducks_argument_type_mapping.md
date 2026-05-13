# Describe how Rducks argument values are passed to R functions

`rducks_argument_type_mapping()` is the package-level source of truth
for the R value shape used when DuckDB argument values are marshalled
into an R function call. It is used by scalar-UDF registration checks
and the nanoarrow scalar-UDF marshalling adapter.

## Usage

``` r
rducks_argument_type_mapping(x = NULL)
```

## Arguments

- x:

  Optional scalar type tokens or constructed `rducks_type` descriptors.
  When `NULL`, all currently implemented DuckDB scalar-UDF scalar
  argument mappings are returned. Composite mappings should be requested
  with constructors such as `INTEGER[]`, `INTEGER[3]`,
  `STRUCT(a = INTEGER)`, and `MAP(VARCHAR, INTEGER)`.

## Value

A data frame with one row per requested type descriptor.

## Details

With `null_handling = "default"`, top-level SQL `NULL` inputs
short-circuit to a SQL `NULL` result and the R function is not called.
The `special_null_argument` column describes the value passed only when
`null_handling = "special"`. This value is type-specific: ordinary R
scalar types receive typed `NA` values, while exact Rducks value
classes, binary values, and top-level composite values receive R `NULL`.
Within homogeneous scalar lists/arrays, SQL `NULL` elements are
represented as typed `NA` values where the child type has an R `NA`
representation; nested composite `NULL` values are represented as R
`NULL`.

The default table contains all scalar descriptors supported by the
nanoarrow scalar-UDF marshalling adapter. `DECIMAL`, `ENUM`, `UNION`,
and composite descriptors can be requested explicitly to inspect their
recursive R function shapes.
