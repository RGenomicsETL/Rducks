# Generic helpers for Rducks value classes

These helpers provide a small common interface for Rducks' exact value
classes used to represent DuckDB-specific values.

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

## Examples

``` r
rducks_value_type(rducks_bigint(1L))
#> [1] "BIGINT"
rducks_value_type(rducks_decimal(1.5, width = 10, scale = 2))
#> [1] "DECIMAL(10, 2)"
rducks_duckdb_literal(rducks_bigint("42"))
#> [1] "'42'::BIGINT"
rducks_duckdb_literal(rducks_uuid("550e8400-e29b-41d4-a716-446655440000"))
#> [1] "'550e8400-e29b-41d4-a716-446655440000'::UUID"
```
