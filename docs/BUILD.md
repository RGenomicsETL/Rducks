# Rducks Extension Build

Rducks builds a DuckDB extension during R package installation. The installed
extension artifact is loaded by `rducks_enable()`.

## Inputs

- `tools/ext/rducks_extension.c`
- native sources under `tools/ext/src/`
- the shared Quack core under `src/quack_core.c` and `src/quack_core.h`
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
Rscript tools/fetch_duckdb_headers.R --ref v1.5.5
```

The script writes to `tools/ext/duckdb_capi/<ref>/` and fetches:

- `src/include/duckdb.h`
- `src/include/duckdb_extension.h`

It records the source ref, file hashes, and local prototype repairs in
`tools/ext/duckdb_capi/<ref>/duckdb_headers.json`. For an already-cloned
DuckDB checkout, use:

```sh
Rscript tools/fetch_duckdb_headers.R --repo /path/to/duckdb --ref v1.5.5
```

## Install-time build

`configure` and `configure.win` compile sources from `tools/ext/`
and write one build-tree payload per declared exact engine version:

```text
inst/rducks_extension/build/v1.5.5/rducks.duckdb_extension
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

Rducks uses DuckDB V1 C extension API entries outside the v1.2.0 stable
struct (scalar-function metadata and data-chunk/vector helpers). DuckDB
stabilized them in C API v1.5.6. `tools/duckdb_capi_abi.sh`, sourced by both
`configure` and `configure.win`, chooses each variant's ABI from its engine
version:

| Engine | Footer ABI | Footer version | Compile flags | Entrypoint |
|:--|:--|:--|:--|:--|
| DuckDB 1.x | `C_STRUCT_UNSTABLE` | the engine version | `-DDUCKDB_EXTENSION_API_VERSION_UNSTABLE=v1.5.5 -DDUCKDB_EXTENSION_API_UNSTABLE_VERSION=\"v1.5.5\"` | `rducks_init_c_api` |
| DuckDB 2.x | `C_STRUCT` | `v1.5.6` | `-DDUCKDB_EXTENSION_API_VERSION_MAJOR=1 -DDUCKDB_EXTENSION_API_VERSION_MINOR=5 -DDUCKDB_EXTENSION_API_VERSION_PATCH=6` | `rducks_init_c_api` |

DuckDB 1.x needs the exact unstable struct: the entries are unstable there, so
DuckDB must validate the extension against the exact unstable struct version
recorded in the matching vendored header metadata. A stable `C_STRUCT` footer
is not a compatibility workaround for those engines.

DuckDB 2.0 treats every `C_STRUCT_UNSTABLE` extension as a V2 C API extension
(`duckdb_extension_v2.h`, entrypoint `rducks_init_c_api_v2`); see `UsesCAPIV2()`
in DuckDB v2.0.0 `src/main/extension/extension_load.cpp`. Rducks is a V1
extension, so its 2.x variants target the stable V1 struct at C API v1.5.6.
Each 2.x variant is still compiled against that engine's vendored headers and
selected by exact engine version. The header compiles out entries newer than
the pin, so using one fails at compile time.

`USE_UNSTABLE_C_API=1` and `RDUCKS_EXTENSION_ABI_TYPE=C_STRUCT_UNSTABLE` remain
the required configure settings and govern the 1.x variants.

## Inspecting unstable API use

Run:

```sh
Rscript -e 'source("tools/used_duckdb_unstable_api.R"); cat(rducks_used_duckdb_unstable_api_markdown("."))'
```

Keep README and release notes aligned with this generated list rather than
hand-writing optimistic ABI claims.
