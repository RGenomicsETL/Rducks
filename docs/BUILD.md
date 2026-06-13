# Rducks Extension Build

Rducks builds a DuckDB extension during R package installation. The installed
extension artifact is loaded by `rducks_enable()`.

## Inputs

- `tools/ext/rducks_extension.c`
- native sources under `tools/ext/src/`
- vendored DuckDB C API headers under `tools/ext/duckdb_capi/`
- vendored NNG and Mbed TLS sources under `tools/ext/third_party/`
- `tools/fetch_duckdb_headers.R`
- `tools/append_extension_metadata.R`

The source package keeps extension sources and vendored dependencies under
`tools/ext/`. During installation, `configure` writes the generated extension
artifact under `inst/rducks_extension/build/` in the build tree. The installed
package then contains only `rducks_extension/build/rducks.duckdb_extension`; the
source/vendor tree is not copied into the installed package.

## Native dependency vendoring

Refresh bundled NNG/Mbed TLS with:

```sh
Rscript tools/vendor_nng_mbedtls.R --force
```

## Header vendoring

Refresh DuckDB headers explicitly:

```sh
Rscript tools/fetch_duckdb_headers.R --ref v1.5.2
```

The script fetches:

- `src/include/duckdb.h`
- `src/include/duckdb_extension.h`

It records the source ref, file hashes, and local prototype repairs in
`tools/ext/duckdb_capi/duckdb_headers.json`. For an already-cloned
DuckDB checkout, use:

```sh
Rscript tools/fetch_duckdb_headers.R --repo /path/to/duckdb --ref v1.5.2
```

## Install-time build

`configure` and `configure.win` compile sources from `tools/ext/`
and write the build-tree payload to:

```text
inst/rducks_extension/build/rducks.duckdb_extension
```

After linking, `tools/append_extension_metadata.R` appends the DuckDB extension
metadata footer. In the installed package this file is available as
`rducks_extension/build/rducks.duckdb_extension`. `cleanup` and `cleanup.win`
remove generated build artifacts from `inst/rducks_extension/build` without
deleting the source tree required for later source-package builds.

## DuckDB C extension ABI

Rducks uses DuckDB C extension API entries that are outside DuckDB's stable C
extension struct (scalar-function metadata and data-chunk/vector helpers).
Configure therefore builds with the unstable C API enabled and the extension
footer advertises an unstable C struct:

```sh
USE_UNSTABLE_C_API=1
RDUCKS_EXTENSION_ABI_TYPE=C_STRUCT_UNSTABLE
```

The build also defines the pinned unstable DuckDB version, for example:

```sh
-DDUCKDB_EXTENSION_API_VERSION_UNSTABLE=v1.5.2
-DDUCKDB_EXTENSION_API_UNSTABLE_VERSION=\"v1.5.2\"
```

A stable `C_STRUCT` footer is not a compatibility workaround. If the extension
calls unstable function-pointer slots, DuckDB must validate it against the exact
unstable struct version recorded in the vendored header metadata.

## Inspecting unstable API use

Run:

```sh
Rscript -e 'source("tools/used_duckdb_unstable_api.R"); cat(rducks_used_duckdb_unstable_api_markdown("."))'
```

Keep README and release notes aligned with this generated list rather than
hand-writing optimistic ABI claims.
