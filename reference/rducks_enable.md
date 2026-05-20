# Enable Rducks on a DuckDB connection

Loads the bundled Rducks DuckDB extension. The registration-safe R UDF
path requires R API work to happen on the recorded main R thread; pass
`threads = "single"` to set `external_threads=1` and `PRAGMA threads=1`
explicitly. `rducks_enable()` also sets DuckDB's
`arrow_lossless_conversion=true` option on the user connection; the
extension applies the same setting to its internal connections so
DuckDB-specific Arrow metadata is preserved for typed scalar-UDF, table,
and query-stream marshalling. After registering UDFs, call
[`rducks_enable_inproc()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable_inproc.md)
to opt into the extension-owned in-process queue.

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
