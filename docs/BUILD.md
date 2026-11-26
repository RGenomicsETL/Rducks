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

The recorded `duckdb_ref` is the C API version of the build, the oldest engine
that can load the extension. The package minimum is separate: it is the
`duckdb` requirement in `DESCRIPTION` and `rducks_min_duckdb_version` in
`R/extension_repository.R`, currently v2.0.0, the first release with extension
repositories. The C API version must not be newer than the package minimum.

## Install-time build

`configure` and `configure.win` compile sources from `tools/ext/` and write two
build-tree files:

```text
inst/rducks_extension/build/rducks.duckdb_extension
inst/rducks_extension/build/rducks.pub
```

The NNG/Mbed TLS static dependency is built during package installation and
linked into the extension. After the link, `tools/append_extension_metadata.R`
appends a DuckDB metadata footer with ABI type `C_STRUCT` and the C API version
from `duckdb_headers.json`.

Configure then compiles `tools/ext/sign/rducks_sign.c` with the vendored Mbed
TLS sources and the build configuration `tools/ext/sign/rducks_sign_config.h`,
and runs it once. It generates an RSA-2048 key, signs the extension the way
DuckDB verifies it (SHA-256 over each 1 MiB segment of everything except the
trailing 256-byte signature, then SHA-256 over the segment digests, signed
with PKCS#1 v1.5), verifies the signature, and writes the signed extension and
the base64 DER public key `rducks.pub`. The private key exists only in memory
while the signer runs, and configure deletes the signer afterwards. The signer
runs on the build machine: a cross build must set `RDUCKS_HOST_CC` to a host
compiler, and a WebAssembly build uses `cc` when `RDUCKS_HOST_CC` is unset. The
signer refuses input that does not end in the metadata footer with a zeroed
signature placeholder.

`cleanup` and `cleanup.win` remove generated build
artifacts from `inst/rducks_extension/build` without deleting the source tree
required for later source-package builds.

## Generated marshalling CI

The generated direct/Quack matrix runs on R release and R 4.3 with the minimum
duckdb version declared in `DESCRIPTION`. `rducks_ci_duckdb_package()` in
`tools/duckdb_version_support.R` selects that exact R package version for
`pak::pkg_install()`, and the installed engine's `SELECT version()` result must
equal it before the workflow builds Rducks and runs the matrix.

A separate R release job installs the latest available duckdb package. Its
engine must be at least the minimum version; the bundled stable C API
extension then loads on it without a new Rducks build. `fail-fast: false` lets
the pinned jobs finish independently of that job.

Run the offline runtime-policy tests from the checkout root with:

```sh
Rscript -e 'stopifnot(tinytest::all_pass(
  tinytest::run_test_file("tools/tests/test_ci_duckdb_runtime.R")
))'
```

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

The streaming query path calls two entries that need
`DUCKDB_API_ALLOW_DEPRECATED`: `duckdb_pending_prepared_streaming`, which has no
other stable V1 form, and `duckdb_result_is_streaming`, which verifies that
DuckDB returned a streaming result. They are part of the stable struct, but they
are the first candidates for removal in a later C API version. Chunks are
fetched with `duckdb_fetch_chunk`.

## Inspecting C API use

Run:

```sh
Rscript -e 'source("tools/used_duckdb_capi.R"); cat(rducks_used_duckdb_capi_markdown("."))'
```

The table groups the API entries that the extension calls by the version band
that stabilized them. The newest band must not exceed `duckdb_ref`. Keep README
and release notes aligned with this generated list.
