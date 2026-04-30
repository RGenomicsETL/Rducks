# Rducks type descriptor helpers

These generic helpers expose the formal DuckDB type descriptor carried
by objects such as `INTEGER`, `INTEGER[]`, `STRUCT(...)`,
`DECIMAL(...)`, `ENUM(...)`, and `UNION(...)`.

## Usage

``` r
rducks_type_token(x, ...)

rducks_type_sql(x, ...)

rducks_type_kind(x, ...)

rducks_type_children(x, ...)

rducks_type_child_names(x, ...)

rducks_type_size(x, ...)

rducks_type_parameters(x, ...)
```

## Arguments

- x:

  A `rducks_type` object.

- ...:

  Reserved for methods.

## Value

`rducks_type_token()` returns the internal wire token;
`rducks_type_sql()` returns the DuckDB SQL spelling;
`rducks_type_kind()` returns the descriptor kind; child and parameter
helpers return descriptor metadata.
