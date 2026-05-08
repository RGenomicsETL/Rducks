# Vendored native dependencies

This directory records source snapshots used by the native Rducks DuckDB
extension. Dependencies are vendored so the extension can statically compile
private C shims instead of depending on nanonext's private binary layout,
system `libnng`, or the nanoarrow R package shared-library symbol table.

## Pins

- NNG `1.11.0` (`v1.11`): https://github.com/nanomsg/nng/archive/refs/tags/v1.11.tar.gz
- Mbed TLS `3.6.5` (`mbedtls-3.6.5`): https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.5/mbedtls-3.6.5.tar.bz2
- Apache Arrow nanoarrow C/IPC `0.9.0.dev-4639910`
  (`apache-arrow-nanoarrow-0.9.0.dev-23-g4639910`, commit `4639910`), stored
  under `inst/rducks_extension/tp/na` to keep source-package tar paths below
  the portable 100-byte limit.

NNG is built with inproc, IPC/Unix-domain, TCP, and WebSocket transports
enabled for the native worker path. Its documentation/manpage snapshot is not
included in the R source package; the vendored NNG `CMakeLists.txt` is patched
to build manpages only when that optional snapshot is present. Mbed TLS is
vendored for the planned TLS transport, but TLS/WSS are not enabled until
certificate and client-auth policy is explicit. Rducks does not use a system
`libnng` or nanonext's private binary layout.

## Namespace and symbol collision discipline

- Vendored nanoarrow is compiled with `-DNANOARROW_NAMESPACE=RducksNanoarrow`.
  This prefixes nanoarrow C/IPC symbols such as `ArrowIpcWriterInit` to
  `RducksNanoarrowArrowIpcWriterInit`, avoiding collisions with the nanoarrow R
  package DLL/shared object when both are loaded into the same R process.
- Vendored flatcc runtime symbols are prefixed in
  `src/rducks_vendor_nanoarrow_prefix.h` (for example
  `flatcc_builder_init` becomes `rducks_flatcc_builder_init`).
- Rducks code should call vendored nanoarrow IPC through Rducks-owned helpers in
  `src/rducks_vendor_ipc_helpers.h`, not by dynamically loading symbols from
  another package.

## Update procedure

Run from the package root:

```sh
Rscript tools/vendor_nng_mbedtls.R --force
```

Nanoarrow is currently refreshed from a local Apache Arrow nanoarrow checkout by
copying the C/IPC sources and flatcc runtime recorded in `versions.json`; keep
that pin updated when refreshing the snapshot.

Then rebuild the package and run at least:

```sh
RDUCKS_DEV_SURFACES=true make test
```

Keep raw NNG calls behind `src/rducks_nng.c`; the rest of Rducks should talk to
Rducks-owned provider/shim functions.
