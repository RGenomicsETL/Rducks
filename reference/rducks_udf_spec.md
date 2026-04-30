# Create an Rducks UDF specification

Create an Rducks UDF specification

## Usage

``` r
rducks_udf_spec(
  name,
  fun,
  args,
  returns,
  mode = c("row", "nanoarrow_lapply", "arrow_nanoarrow")
)
```

## Arguments

- name:

  SQL function name.

- fun:

  R function.

- args:

  Rducks type objects or scalar type tokens.

- returns:

  Rducks return type object or scalar type token.

- mode:

  Registration mode. `"row"` is implemented now and calls the R function
  once per row through the native Rducks DuckDB extension. The
  `"nanoarrow_lapply"` and `"arrow_nanoarrow"` modes are reserved for
  future batch UDF paths.

## Value

Object of class `rducks_udf_spec`.
