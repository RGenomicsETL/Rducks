# Rducks Extension Build

Rducks builds its own small DuckDB extension during R package installation.

## What is bundled

- `inst/rducks_extension/rducks_extension.c`
- DuckDB C API headers under `inst/rducks_extension/duckdb_capi/`
- `tools/fetch_duckdb_headers.R`
- `tools/append_extension_metadata.R`

There is no DuckTinyCC extension dependency and no embedded TinyCC runtime.
Rtinycc remains the intended code-generation/compiler dependency for future
arbitrary-shape wrappers; Rducks does not need to embed TinyCC assets.

## Header vendoring

DuckDB C API headers are refreshed explicitly with:

```sh
Rscript tools/fetch_duckdb_headers.R --ref v1.5.0
```

The script fetches exactly these files from the DuckDB repository:

- `src/include/duckdb.h`
- `src/include/duckdb_extension.h`

It then repairs strict C prototypes such as `duckdb_create_scalar_function()` to
`duckdb_create_scalar_function(void)` in both the public C API header and the
extension API function-pointer table. The generated
`inst/rducks_extension/duckdb_capi/duckdb_headers.json` records the DuckDB ref,
source, file hashes, and repair counts.

For offline/local refresh from an explicit DuckDB checkout:

```sh
Rscript tools/fetch_duckdb_headers.R --repo /path/to/duckdb --ref v1.5.0
```

## Install-time build

`configure` on Unix/macOS and `configure.win` on Windows compile
`rducks_extension.c` into:

```text
inst/rducks_extension/build/rducks.duckdb_extension
```

Then the configure script appends the DuckDB extension metadata trailer using
`tools/append_extension_metadata.R`, following the same metadata layout used by
DuckHTS.

`cleanup` and `cleanup.win` remove generated extension build artifacts and
native object/shared-library leftovers.

## Unstable DuckDB C API and metadata

Rducks uses DuckDB's unstable C extension API by default because planned Arrow
batch paths need API members that are behind `DUCKDB_EXTENSION_API_VERSION_UNSTABLE`.
The configure scripts therefore default to:

```sh
USE_UNSTABLE_C_API=1
```

This adds a compile flag like:

```sh
-DDUCKDB_EXTENSION_API_VERSION_UNSTABLE=v1.2.0
```

The vendored header ref is newer than the stable C extension API version string:
Rducks pins DuckDB headers to `v1.5.0` so future nanoarrow batch work can use
unstable chunk-to-Arrow helpers such as `duckdb_data_chunk_to_arrow()` and
`duckdb_data_chunk_from_arrow()`, plus scalar `set_init`/`get_state` for
per-worker execution scratch. DuckDB's stable C extension ABI version in these
headers is still `v1.2.0`, so the metadata footer continues to advertise the
stable `C_STRUCT` ABI version while the build exposes newer unstable members.
This requires a DuckDB runtime new enough to provide those function-pointer
slots; the R package therefore imports `duckdb (>= 1.5.0)`.

Unlike DuckDB's CMake/extension-ci-tools flow, Rducks appends its own metadata
footer with `tools/append_extension_metadata.R`. The metadata ABI type is
controlled separately:

```sh
RDUCKS_EXTENSION_ABI_TYPE=C_STRUCT
```

That default is intentional for this R package build: we compile with the
unstable struct members visible, but keep the footer ABI as `C_STRUCT` to avoid
DuckDB's exact-version `C_STRUCT_UNSTABLE` loader check across DuckDB patch
versions. If exact-version enforcement is desired for a diagnostic build, use:

```sh
RDUCKS_EXTENSION_ABI_TYPE=C_STRUCT_UNSTABLE R CMD INSTALL .
```

Do not accidentally mix these knobs: if unstable C API macros are injected from
external compiler flags, set `USE_UNSTABLE_C_API=1` so the build configuration is
explicit.
