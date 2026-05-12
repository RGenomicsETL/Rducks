# Vendored native dependencies

This directory contains source snapshots compiled into the Rducks DuckDB
extension. Vendored code lives under `third_party/`; Rducks-owned adapter and
shim code lives under `../src/`.

## Layout

- `nng/`: NNG 1.11.0 source subset used for native worker transport.
- `mbedtls/`: Mbed TLS 3.6.5 source subset kept for future TLS transport work.
- `na/`: path-budgeted Apache Arrow nanoarrow C/IPC snapshot, including the
  flatcc runtime needed by nanoarrow IPC.
- `patches/`: local patch ledger for edited vendored sources.
- `versions.json`: dependency pins.
- `nanoarrow.json`: nanoarrow-specific pin written by `tools/vendor_nanoarrow.R`.

`na` is intentionally short. The files are installed under an R package `inst/`
path, and the full `third_party/nanoarrow/...` spelling would push several
flatcc portable headers past R's portable filename budget.

## Pins

- NNG `1.11.0` (`v1.11`):
  <https://github.com/nanomsg/nng/archive/refs/tags/v1.11.tar.gz>
- Mbed TLS `3.6.5` (`mbedtls-3.6.5`):
  <https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.5/mbedtls-3.6.5.tar.bz2>
- Apache Arrow nanoarrow C/IPC `0.9.0.dev-4639910`
  (`apache-arrow-nanoarrow-0.9.0.dev-23-g4639910`, commit `4639910`):
  <https://github.com/apache/arrow-nanoarrow/archive/4639910.tar.gz>

## Symbol discipline

- Vendored nanoarrow is compiled with `-DNANOARROW_NAMESPACE=RducksNanoarrow`.
- Vendored flatcc runtime symbols are prefixed in
  `../src/rducks_vendor_nanoarrow_prefix.h`.
- Rducks code calls vendored nanoarrow IPC through
  `../src/rducks_vendor_ipc_helpers.h`.
- Do not `dlopen()` or `dlsym()` the nanoarrow R package shared object for IPC
  implementation symbols.
- Keep raw NNG use behind `../src/rducks_nng.c` and Rducks-owned provider
  functions.

## Refresh commands

Refresh NNG and Mbed TLS:

```sh
Rscript tools/vendor_nng_mbedtls.R --force
```

Refresh nanoarrow plus its flatcc runtime subset:

```sh
Rscript tools/vendor_nanoarrow.R --force
```

For a local nanoarrow checkout:

```sh
Rscript tools/vendor_nanoarrow.R --force --repo=/path/to/arrow-nanoarrow
```

After any vendor refresh, rebuild and run at least:

```sh
make test
```

If vendored NNG files are edited, refresh the matching patch files under
`inst/rducks_extension/third_party/patches/nng/` before committing.
