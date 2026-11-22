# Locate the bundled Rducks DuckDB extension

Rducks builds one extension per platform against DuckDB's stable C
extension API. DuckDB loads it on every engine release that supports
that API version; see
[`rducks_extension_capi_version()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_extension_capi_version.md).

## Usage

``` r
rducks_extension_path()
```

## Value

Character scalar path to the bundled `rducks.duckdb_extension`.

## Examples

``` r
rducks_extension_path()
#> [1] "/home/runner/work/_temp/Library/Rducks/rducks_extension/build/rducks.duckdb_extension"
```
