# Check that an R value is compatible with a DuckDB type

This is a pre-marshalling guard for Rducks type descriptors. It checks
the R value shape that the marshaller expects for scalar, decimal, enum,
list, array, struct, map, and union descriptors.

## Usage

``` r
rducks_check_value(type, x, size = NULL, what = "value")

rducks_check_argument(type, x, name = "argument")

rducks_check_return(type, x)
```

## Arguments

- type:

  A `rducks_type` descriptor such as `INTEGER`, `INTEGER[]`,
  `STRUCT(a = INTEGER)`, or a character scalar token accepted by
  [`rducks_type_normalize()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_type_normalize.md).

- x:

  R value to check.

- size:

  Optional exact length for scalar/vector checks.

- what:

  Label used in error messages.

- name:

  Argument label used by `rducks_check_argument()` in error messages.

## Value

`x`, invisibly, on success.

## Examples

``` r
rducks_check_value(INTEGER, 42L)
rducks_check_value(VARCHAR, "hello")
rducks_check_argument(DOUBLE, 3.14, name = "x")
rducks_check_return(BOOLEAN, TRUE)
```
