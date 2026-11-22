# Rducks Extension Build

Rducks builds a DuckDB extension during R package installation. The installed
extension artifact is loaded by `rducks_enable()`.

## Inputs

- `tools/ext/rducks_extension.c`
- native sources under `tools/ext/src/`
- the shared Quack core under `src/quack_core.c` and `src/quack_core.h`
- vendored DuckDB C API headers under `tools/ext/duckdb_capi/`, with their
  provenance in `tools/ext/duckdb_capi/duckdb_headers.json`
- vendored NNG and Mbed TLS sources under `tools/ext/third_party/`
- `tools/fetch_duckdb_headers.R`
- `tools/append_extension_metadata.R`

The source package keeps extension sources and vendored dependencies under
`tools/ext/`. During installation, `configure` writes the generated extension
artifact to `inst/rducks_extension/build/rducks.duckdb_extension` in the build
tree. The installed package contains only
`rducks_extension/build/rducks.duckdb_extension`; the source/vendor tree is not
copied into the installed package.

## Native dependency vendoring

Refresh bundled NNG/Mbed TLS with:

```sh
Rscript tools/vendor_nng_mbedtls.R --force
```

## Header vendoring

Refresh the DuckDB headers explicitly:

```sh
Rscript tools/fetch_duckdb_headers.R --ref v1.5.6
```

The script writes to `tools/ext/duckdb_capi/` and fetches:

- `src/include/duckdb.h`
- `src/include/duckdb_extension.h`

It records the source ref, file hashes, and local prototype repairs in
`tools/ext/duckdb_capi/duckdb_headers.json`. For an already-cloned DuckDB
checkout, use:

```sh
Rscript tools/fetch_duckdb_headers.R --repo /path/to/duckdb --ref v1.5.6
```

The recorded `duckdb_ref` is the C API version of the build and the minimum
DuckDB engine version. Keep the `duckdb` requirement in `DESCRIPTION` at the
same release.

## Install-time build

`configure` and `configure.win` compile sources from `tools/ext/` and write one
build-tree payload:

```text
inst/rducks_extension/build/rducks.duckdb_extension
```

The NNG/Mbed TLS static dependency is built during package installation and
linked into the extension. After the link, `tools/append_extension_metadata.R`
appends a DuckDB metadata footer with ABI type `C_STRUCT` and the C API version
from `duckdb_headers.json`. `cleanup` and `cleanup.win` remove generated build
artifacts from `inst/rducks_extension/build` without deleting the source tree
required for later source-package builds.

## DuckDB C extension ABI

Rducks uses DuckDB's stable C extension API. Configure derives the API version
from `duckdb_ref` and defines it for the extension header, for example:

```sh
-DDUCKDB_EXTENSION_API_VERSION_MAJOR=1
-DDUCKDB_EXTENSION_API_VERSION_MINOR=5
-DDUCKDB_EXTENSION_API_VERSION_PATCH=6
```

The header then exposes every API band up to that version. DuckDB loads a
`C_STRUCT` extension on any engine whose stable C API includes the recorded
version, so one artifact serves all such engine releases. `rducks_enable()`
reads the version from the footer and fails before `LOAD` on an older engine.

Configure and `tools/ext/rducks_extension.c` reject
`DUCKDB_EXTENSION_API_VERSION_UNSTABLE`. An unstable build would need a
`C_STRUCT_UNSTABLE` footer, which DuckDB loads only on the exact engine release
that it was built for.

The streaming query path calls four entries that need
`DUCKDB_API_ALLOW_DEPRECATED` (`duckdb_pending_prepared_streaming`,
`duckdb_stream_fetch_chunk`, `duckdb_result_get_chunk`,
`duckdb_result_is_streaming`). They are part of the stable struct, but they are
the first candidates for removal in a later C API version.

## Inspecting C API use

Run:

```sh
Rscript -e 'source("tools/used_duckdb_capi.R"); cat(rducks_used_duckdb_capi_markdown("."))'
```

The table groups the API entries that the extension calls by the version band
that stabilized them. The newest band must not exceed `duckdb_ref`. Keep README
and release notes aligned with this generated list.
