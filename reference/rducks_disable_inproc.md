# Disable in-process queued scalar execution

Switches a Rducks-enabled DuckDB connection back to the direct
single-lane scalar backend. Optionally updates DuckDB thread settings at
the same time.

## Usage

``` r
rducks_disable_inproc(con, threads = NULL, external_threads = threads)
```

## Arguments

- con:

  A `duckdb_connection`.

- threads:

  Optional positive integer to set with `PRAGMA threads`.

- external_threads:

  Optional positive integer to set with `SET external_threads`. Defaults
  to `threads`.

## Value

`con`, invisibly.
