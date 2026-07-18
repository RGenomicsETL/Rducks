# Rducks Extension Build

Rducks builds a DuckDB extension during R package installation. The installed
extension artifact is loaded by `rducks_enable()`.

## Inputs

- `tools/ext/rducks_extension.c`
- native sources under `tools/ext/src/`
- exact-version vendored DuckDB C API headers under `tools/ext/duckdb_capi/v*/`
- `tools/ext/duckdb_capi/versions.txt`, the supported engine-version manifest
- vendored NNG and Mbed TLS sources under `tools/ext/third_party/`
- `tools/fetch_duckdb_headers.R`
- `tools/append_extension_metadata.R`

The source package keeps extension sources and vendored dependencies under
`tools/ext/`. During installation, `configure` writes the generated extension
artifacts under `inst/rducks_extension/build/<duckdb-version>/` in the build
tree. The installed package contains one
`rducks_extension/build/<duckdb-version>/rducks.duckdb_extension` artifact per
supported exact DuckDB engine release; the source/vendor tree is not copied into
the installed package.

## Native dependency vendoring

Refresh bundled NNG/Mbed TLS with:

```sh
Rscript tools/vendor_nng_mbedtls.R --force
```

## Header vendoring

Refresh DuckDB headers explicitly, once for each release listed in
`tools/ext/duckdb_capi/versions.txt`:

```sh
Rscript tools/fetch_duckdb_headers.R --ref v1.5.4
```

The script writes to `tools/ext/duckdb_capi/<ref>/` and fetches:

- `src/include/duckdb.h`
- `src/include/duckdb_extension.h`

It records the source ref, file hashes, and local prototype repairs in
`tools/ext/duckdb_capi/<ref>/duckdb_headers.json`. For an already-cloned
DuckDB checkout, use:

```sh
Rscript tools/fetch_duckdb_headers.R --repo /path/to/duckdb --ref v1.5.4
```

## Install-time build

`configure` and `configure.win` compile sources from `tools/ext/`
and write one build-tree payload per declared exact engine version:

```text
inst/rducks_extension/build/v1.5.4/rducks.duckdb_extension
```

The NNG/Mbed TLS static dependency is built once per package installation and
linked into each extension variant. After each link,
`tools/append_extension_metadata.R` appends a footer for that exact DuckDB
version. At runtime, `rducks_enable()` queries `SELECT version()` on the target
connection and selects only the exact matching bundled artifact. Unsupported
versions fail before `LOAD`; Rducks never falls back to a differently versioned
unstable ABI.

For a deliberately reduced developer build, `RDUCKS_DUCKDB_VERSIONS` may be a
whitespace-separated subset of versions declared in `versions.txt`. Release and
binary-package builds should leave it unset so every declared variant is
included. `cleanup` and `cleanup.win` remove generated build artifacts from
`inst/rducks_extension/build` without deleting the source tree required for
later source-package builds.

## DuckDB C extension ABI

Rducks uses DuckDB C extension API entries that are outside DuckDB's stable C
extension struct (scalar-function metadata and data-chunk/vector helpers).
Configure therefore builds with the unstable C API enabled and the extension
footer advertises an unstable C struct:

```sh
USE_UNSTABLE_C_API=1
RDUCKS_EXTENSION_ABI_TYPE=C_STRUCT_UNSTABLE
```

Each variant defines its own pinned unstable DuckDB version, for example:

```sh
-DDUCKDB_EXTENSION_API_VERSION_UNSTABLE=v1.5.4
-DDUCKDB_EXTENSION_API_UNSTABLE_VERSION=\"v1.5.4\"
```

A stable `C_STRUCT` footer is not a compatibility workaround. If the extension
calls unstable function-pointer slots, DuckDB must validate it against the exact
unstable struct version recorded in the matching vendored header metadata.
Compiling exact variants also avoids assuming that equal-looking headers imply
ABI compatibility across future patch releases.

## Inspecting unstable API use

Run:

```sh
Rscript -e 'source("tools/used_duckdb_unstable_api.R"); cat(rducks_used_duckdb_unstable_api_markdown("."))'
```

Keep README and release notes aligned with this generated list rather than
hand-writing optimistic ABI claims.
