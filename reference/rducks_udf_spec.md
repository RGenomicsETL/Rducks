# Create an Rducks UDF specification

Create an Rducks UDF specification

## Usage

``` r
rducks_udf_spec(name, fun, args, returns, mode = "row")
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
  once per row through the native Rducks DuckDB extension.

## Value

Object of class `rducks_udf_spec`.
