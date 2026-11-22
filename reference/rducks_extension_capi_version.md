# Read the DuckDB C API version of an Rducks extension

Reads the DuckDB C API version that the extension was built against from
the metadata footer of the extension file. This is the oldest DuckDB
engine release that can load the extension.

## Usage

``` r
rducks_extension_capi_version(extension_path = rducks_extension_path())
```

## Arguments

- extension_path:

  Path to a `rducks.duckdb_extension` file.

## Value

Character scalar such as `"v1.5.6"`.

## Examples

``` r
rducks_extension_capi_version()
#> [1] "v1.5.6"
```
