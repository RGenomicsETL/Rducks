# Generic helpers for Rducks value classes

These helpers provide a small common interface for Rducks' exact value
classes used to represent DuckDB-specific values before native UDF
marshalling for those types is enabled.

## Usage

``` r
rducks_value_type(x, ...)

rducks_duckdb_literal(x, ...)
```

## Arguments

- x:

  A value object.

- ...:

  Reserved for methods.

## Value

`rducks_value_type()` returns a DuckDB type string.
