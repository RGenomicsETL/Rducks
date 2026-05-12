# Rducks Extension Build

Rducks builds a DuckDB extension during R package installation. The installed
extension artifact is loaded by `rducks_enable()`.

## Inputs

- `inst/rducks_extension/rducks_extension.c`
- native sources under `inst/rducks_extension/src/`
- vendored DuckDB C API headers under `inst/rducks_extension/duckdb_capi/`
- vendored NNG, Mbed TLS, nanoarrow C/IPC, and flatcc sources under
  `inst/rducks_extension/third_party/`
- `tools/fetch_duckdb_headers.R`
- `tools/append_extension_metadata.R`

## Native dependency vendoring

Refresh bundled NNG/Mbed TLS with:

```sh
Rscript tools/vendor_nng_mbedtls.R --force
```

Refresh bundled nanoarrow C/IPC plus the flatcc runtime subset with:

```sh
Rscript tools/vendor_nanoarrow.R --force
```

Nanoarrow is stored under `inst/rducks_extension/third_party/na`; the short
basename keeps installed source paths portable while still keeping third-party
code out of the extension source directory.

## Header vendoring

Refresh DuckDB headers explicitly:

```sh
Rscript tools/fetch_duckdb_headers.R --ref v1.5.2
```

The script fetches:

- `src/include/duckdb.h`
- `src/include/duckdb_extension.h`

It records the source ref, file hashes, and local prototype repairs in
`inst/rducks_extension/duckdb_capi/duckdb_headers.json`. For an already-cloned
DuckDB checkout, use:

```sh
Rscript tools/fetch_duckdb_headers.R --repo /path/to/duckdb --ref v1.5.2
```

## Install-time build

`configure` and `configure.win` build:

```text
inst/rducks_extension/build/rducks.duckdb_extension
```

After linking, `tools/append_extension_metadata.R` appends the DuckDB extension
metadata footer. `cleanup` and `cleanup.win` remove generated build artifacts.

## DuckDB C extension ABI

Rducks uses DuckDB C extension API entries that are outside DuckDB's stable C
extension struct, including Arrow C Data conversion functions and scalar-function
state hooks. Configure therefore builds with the unstable C API enabled and the
extension footer advertises an unstable C struct:

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
