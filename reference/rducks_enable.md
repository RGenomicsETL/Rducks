# Enable Rducks on a DuckDB connection

Loads the bundled Rducks DuckDB extension. The registration-safe R UDF
path requires R API work to happen on the recorded main R thread; pass
`threads = "single"` to set `external_threads=1` and `PRAGMA threads=1`
explicitly. `rducks_enable()` also sets DuckDB's
`arrow_lossless_conversion=true` option on the user connection; the
extension applies the same setting to its internal connections so
DuckDB-specific Arrow metadata is preserved for typed scalar-UDF, table,
and query-stream marshalling. Use
[`rducks_set_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_set_execution_plan.md)
before scalar-UDF registration to select a non-reference marshalling or
concurrency plan.

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
db <- duckdb::dbConnect(duckdb::duckdb())
rducks_enable(db)
#> Error in duckdb_result(connection = conn, stmt_lst = stmt_lst, arrow = arrow): Invalid Error: IO Error: Extension "/home/runner/work/_temp/Library/Rducks/rducks_extension/build/rducks.duckdb_extension" could not be loaded because its signature is either missing or invalid and unsigned extensions are disabled by configuration (allow_unsigned_extensions)
#> ℹ Context: rapi_execute
#> ℹ Error type: INVALID
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
