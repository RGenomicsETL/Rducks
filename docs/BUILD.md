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
Rscript tools/fetch_duckdb_headers.R --ref v1.2.0
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
Rscript tools/fetch_duckdb_headers.R --repo /path/to/duckdb --ref v1.2.0
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
