# DuckDB Version Compatibility

## Why Rducks ships exact-version extensions

Rducks calls entries from DuckDB’s unstable C extension API. DuckDB
therefore loads Rducks through the `C_STRUCT_UNSTABLE` ABI, where an
extension compiled for one DuckDB engine release must not be treated as
compatible with another release, even when the relevant headers happen
to look unchanged.

Rducks addresses this at package installation rather than at first use.
The source package vendors headers for a bounded set of DuckDB releases
and compiles one inexpensive Rducks extension variant against each
header set. The current bundle contains:

| DuckDB engine version | Bundled extension |
|:----------------------|:------------------|
| `v1.5.0`              | yes               |
| `v1.5.1`              | yes               |
| `v1.5.2`              | yes               |
| `v1.5.3`              | yes               |
| `v1.5.4`              | yes               |

This table is generated directly from
`tools/ext/duckdb_capi/versions.txt`, the same manifest consumed by the
native build. The list is an explicit release policy, not an ABI
compatibility claim for versions outside the table.

## Runtime selection

`rducks_enable(con)` asks the target connection for `SELECT version()`.
It then loads only the artifact whose directory has that exact engine
version:

``` text
rducks_extension/build/<duckdb-version>/rducks.duckdb_extension
```

The connection is authoritative. Selection does not assume that an
installed R package version necessarily describes every DuckDB
connection passed to Rducks. There is no nearest-version or same-minor
fallback.

You can inspect the default artifact selected for the installed `duckdb`
package:

``` r

rducks_extension_path()
```

An explicit `extension_path` remains available for development and
custom builds, but it does not make incompatible binaries safe. DuckDB
validates the unstable ABI metadata when it loads the file.

## Unsupported versions

If the target engine is outside the bundled set,
[`rducks_enable()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable.md)
fails before `LOAD` and reports the versions available in the installed
Rducks package. This is intentional: silently loading an artifact
compiled for another unstable ABI could produce incorrect calls through
DuckDB’s function table.

To diagnose a mismatch, compare the connection version and bundled path:

``` r

DBI::dbGetQuery(con, "SELECT version() AS version")
rducks_extension_path()
```

Install an Rducks release that bundles the exact engine version, or
build a matching development variant. Downgrading or upgrading `duckdb`
without also checking the Rducks support window can leave no compatible
artifact.

## Maintainer workflow

Supported versions are declared in `tools/ext/duckdb_capi/versions.txt`.
Before adding a release, vendor its exact headers and provenance
metadata:

``` sh
Rscript tools/fetch_duckdb_headers.R --ref v1.5.4
```

`configure` and `configure.win` validate every declared header set,
build the vendored NNG dependency once, compile one Rducks extension per
DuckDB version, and append matching DuckDB extension metadata to each
artifact. Release builds must leave `RDUCKS_DUCKDB_VERSIONS` unset so
the complete declared bundle is installed. See `docs/BUILD.md` in the
source repository for the native build and ABI details.
