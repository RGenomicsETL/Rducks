# Enable Rducks on a DuckDB connection

Loads the bundled Rducks DuckDB extension. The registration-safe R UDF
path requires R API work to happen on the recorded main R thread; pass
`threads = "single"` to set `external_threads=1` and `PRAGMA threads=1`
explicitly. Use
[`rducks_set_execution_plan()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_set_execution_plan.md)
before scalar-UDF registration to select direct serial or queued
in-process execution.

## Usage

``` r
rducks_enable(con, extension_path = NULL, threads = c("unchanged", "single"))
```

## Arguments

- con:

  A `duckdb_connection`.

- extension_path:

  Optional explicit extension path. `NULL` selects the bundled artifact
  matching the exact engine version reported by `con`.

- threads:

  Either `"unchanged"` or `"single"`.

## Value

`con`, invisibly.

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#> duckdb keeps downloaded extensions and secrets in a temporary directory:
#> ℹ /tmp/RtmpwFko0t/duckdb
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
