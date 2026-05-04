# Disable in-process queued R UDF execution

Switches a Rducks-enabled DuckDB connection back to the direct
single-lane backend. Optionally updates DuckDB thread settings at the
same time.

## Usage

``` r
rducks_disable_inproc(con, threads = NULL, external_threads = NULL)
```

## Arguments

- con:

  A `duckdb_connection`.

- threads:

  Optional positive integer to set with `PRAGMA threads`.

- external_threads:

  Optional positive integer to set with `SET external_threads`. Use
  `NULL` to leave unchanged.

## Value

`con`, invisibly.
