# Locate a version-matched Rducks DuckDB extension

Rducks bundles one extension build per supported DuckDB engine release
and selects the build for an exact engine version. DuckDB 1.x builds use
the exact-version unstable C extension ABI, so a build for one 1.x
release must not be loaded by another. DuckDB 2.x builds use the stable
V1 C extension ABI pinned to C API v1.5.6; Rducks still selects them by
exact engine version.

## Usage

``` r
rducks_extension_path(duckdb_version = NULL)
```

## Arguments

- duckdb_version:

  Exact DuckDB engine version, with or without the `v` prefix (for
  example, `"v1.5.5"`). `NULL` uses the engine version reported by the
  installed `duckdb` package.

## Value

Character scalar path to the matching `rducks.duckdb_extension`.

## Examples

``` r
rducks_extension_path()
#> [1] "/home/runner/work/_temp/Library/Rducks/rducks_extension/build/v2.0.0/rducks.duckdb_extension"
```
