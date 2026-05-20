# Rducks NNG patches

These patch files document intentional local divergence from the vendored NNG
snapshot under `tools/ext/third_party/nng/`.

- `0001-optional-nng-manpages.patch` keeps NNG's optional manpage directory out
  of the R source package while still allowing CMake to configure when that
  snapshot is absent.
- `0002-windows-rtools42-timespec-fallback.patch` carries the Rtools MinGW
  `timespec_get()` fallback used by `ducknng` so Windows CI builds the bundled
  NNG library.
- `0003-windows-rtools-warning-fixes.patch` fixes Rtools/GCC warnings in the
  Windows platform layer without compiler-wide suppression.

When editing vendored NNG files, refresh the matching patch file before
committing so the ledger stays synchronized with `third_party/nng/`. These are
zero-context patch files to keep repository whitespace checks clean; apply them
with `git apply --unidiff-zero` if direct application is needed.
