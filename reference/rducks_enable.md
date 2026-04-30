# Enable Rducks on a DuckDB connection

Loads the bundled Rducks DuckDB extension. The current direct R callback
execution mode requires single-thread DuckDB execution; pass
`threads = "single"` to set `PRAGMA threads=1` explicitly.
Registration-time checks enforce the setting, and native execution
guards defensively refuse to call R from DuckDB worker threads.

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
