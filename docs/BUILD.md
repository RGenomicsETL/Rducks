# Rducks Extension Build

Rducks builds its own small DuckDB extension during R package installation.

## What is bundled

- `inst/rducks_extension/rducks_extension.c`
- DuckDB C API headers under `inst/rducks_extension/duckdb_capi/`
- `tools/fetch_duckdb_headers.R`
- `tools/append_extension_metadata.R`

There is no external DuckDB extension dependency and no runtime code-generation
dependency. Current row callbacks are handled by the Rducks extension using
DuckDB chunk-to-Arrow APIs and nanoarrow.

## Header vendoring

DuckDB C API headers are refreshed explicitly with:

```sh
Rscript tools/fetch_duckdb_headers.R --ref v1.5.2
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
Rscript tools/fetch_duckdb_headers.R --repo /path/to/duckdb --ref v1.5.2
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

Rducks uses DuckDB's unstable C extension API because the current Arrow-backed
row path calls API members that are behind `DUCKDB_EXTENSION_API_VERSION_UNSTABLE`,
including `duckdb_data_chunk_to_arrow()`, `duckdb_data_chunk_from_arrow()`,
`duckdb_to_arrow_schema()`, and `duckdb_schema_from_arrow()`.

The configure scripts therefore require:

```sh
USE_UNSTABLE_C_API=1
RDUCKS_EXTENSION_ABI_TYPE=C_STRUCT_UNSTABLE
```

This adds compile flags like:

```sh
-DDUCKDB_EXTENSION_API_VERSION_UNSTABLE=v1.5.2
-DDUCKDB_EXTENSION_API_UNSTABLE_VERSION=\"v1.5.2\"
```

Unlike DuckDB's CMake/extension-ci-tools flow, Rducks appends its own metadata
footer with `tools/append_extension_metadata.R`. Because the Arrow path uses
unstable function-pointer slots, the footer must advertise `C_STRUCT_UNSTABLE`.
A stable `C_STRUCT` footer is not a compatibility workaround here: it can cause
DuckDB to validate the extension against the stable v1.2 C extension struct while
Rducks calls newer Arrow entries. `C_STRUCT_UNSTABLE` intentionally makes the
loader require the exact DuckDB version recorded in
`inst/rducks_extension/duckdb_capi/duckdb_headers.json`.
