# Locate a version-matched Rducks DuckDB extension

Rducks uses DuckDB's unstable C extension ABI, so an extension built for
one DuckDB engine release must not be loaded by another. This helper
selects the bundled artifact for an exact engine version.

## Usage

``` r
rducks_extension_path(duckdb_version = NULL)
```

## Arguments

- duckdb_version:

  Exact DuckDB engine version, with or without the `v` prefix (for
  example, `"v1.5.4"`). `NULL` uses the engine version reported by the
  installed `duckdb` package.

## Value

Character scalar path to the matching `rducks.duckdb_extension`.

## Examples

``` r
rducks_extension_path()
#> [1] "/home/runner/work/_temp/Library/Rducks/rducks_extension/build/v1.5.4/rducks.duckdb_extension"
```
