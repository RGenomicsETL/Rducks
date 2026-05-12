# Format a DuckDB scalar function signature

Format a DuckDB scalar function signature

## Usage

``` r
rducks_duckdb_signature(name, args, returns)
```

## Arguments

- name:

  SQL function name.

- args:

  Argument type descriptors.

- returns:

  Return type descriptor.

## Value

Character scalar signature such as `f(INTEGER) -> DOUBLE`.
