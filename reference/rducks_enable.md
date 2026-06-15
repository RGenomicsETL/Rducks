# Enable Rducks on a DuckDB connection

Loads the bundled Rducks DuckDB extension. The registration-safe R UDF
path requires R API work to happen on the recorded main R thread; pass
`threads = "single"` to set `external_threads=1` and `PRAGMA threads=1`
explicitly. Use
[`rducks_set_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_set_execution_plan.md)
before scalar-UDF registration to select direct serial or queued
in-process execution.

## Usage

``` r
rducks_enable(
  con,
  extension_path = rducks_extension_path(),
  threads = c("unchanged", "single")
)
```

## Arguments

- con:

  A `duckdb_connection`.

- extension_path:

  Extension path. Defaults to
  [`rducks_extension_path()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_extension_path.md).

- threads:

  Either `"unchanged"` or `"single"`.

## Value

`con`, invisibly.

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
rducks_enable(db)
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
