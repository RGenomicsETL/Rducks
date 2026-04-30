# Describe how Rducks argument values are passed to R callbacks

`rducks_argument_type_mapping()` is the package-level source of truth
for the R value shape used when DuckDB argument values are marshalled
into an R callback. It is used by registration checks and wrapper code
generation.

## Usage

``` r
rducks_argument_type_mapping(x = NULL)
```

## Arguments

- x:

  Optional scalar type tokens or constructed `rducks_type` objects. When
  `NULL`, all currently implemented row-mode scalar argument mappings
  are returned. Composite mappings should be requested with constructors
  such as `INTEGER[]`, `INTEGER[3]`, `STRUCT(a = INTEGER)`, and
  `MAP(VARCHAR, INTEGER)`.

## Value

A data frame with one row per requested type token.

## Details

With `null_handling = "default"`, top-level SQL `NULL` inputs
short-circuit to a SQL `NULL` result and the R callback is not called.
The `sql_null_in_callback` column describes the value passed only when
`null_handling = "special"`. For composite inputs, top-level `NULL`
values are passed as R `NULL`; `NULL` elements in homogeneous scalar
lists/arrays are represented as typed `NA` values, while nested
composite `NULL` values are represented as R `NULL`.

The default table contains all scalar types supported by row-mode native
marshalling. `DECIMAL`, `ENUM`, `UNION`, and composite descriptors can
be requested explicitly to inspect their recursive R callback shapes.
