# DuckDB configuration for a connection that loads Rducks

Returns `config` with the two settings that let
[`rducks_enable()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_enable.md)
load the signed Rducks extension without writing to the home directory:
extension repositories are allowed, and DuckDB keeps its extension
repository records in a directory below
[`tempdir()`](https://rdrr.io/r/base/tempfile.html). DuckDB accepts
`extension_repository_directory` only at startup, so pass the result to
[`duckdb::duckdb()`](https://r.duckdb.org/reference/duckdb.html).

## Usage

``` r
rducks_duckdb_config(config = list())
```

## Arguments

- config:

  A named list of further DuckDB configuration options. Entries for
  `allow_extension_repositories` or `extension_repository_directory` are
  kept as given.

## Value

A named list for the `config` argument of
[`duckdb::duckdb()`](https://r.duckdb.org/reference/duckdb.html).

## Examples

``` r
# \donttest{
db <- DBI::dbConnect(duckdb::duckdb(config = rducks_duckdb_config()))
#> duckdb keeps downloaded extensions and secrets in a temporary directory:
#> ℹ /tmp/Rtmp1gorHK/duckdb
#> This is removed when the R session ends.
#> • Extensions are re-downloaded each session.
#> • Secrets are lost.
#> ℹ Run duckdb(shared_home = TRUE) (or create ~/.duckdb) to keep them (suitable for most users).
#> ℹ Run duckdb(shared_home = FALSE) to accept the temporary directory (and silence this message).
#> ℹ See ?duckdb_storage for details and alternatives.
rducks_enable(db)
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
