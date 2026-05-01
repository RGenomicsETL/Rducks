# Enable Rducks on a DuckDB connection

Loads the bundled Rducks DuckDB extension. The current direct R function
execution mode requires R API work to happen on the calling R thread;
pass `threads = "single"` to set `external_threads=1` and
`PRAGMA threads=1` explicitly for registration. During execution,
worker-thread UDF chunks are queued back to the calling R thread instead
of calling R from workers.

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
