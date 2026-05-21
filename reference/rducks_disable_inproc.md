# Disable in-process queued scalar-UDF execution

Switches a Rducks-enabled DuckDB connection back to the direct serial
backend. Optionally updates DuckDB thread settings at the same time.

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

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
rducks_enable(db)
rducks_enable_inproc(db)
rducks_disable_inproc(db)
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
