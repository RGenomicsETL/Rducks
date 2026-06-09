# Vendored native dependencies

Rducks vendors only NNG and Mbed TLS for the native worker transport. The
Arrow/nanoarrow and flatcc vendor trees were removed with the no-Arrow data
plane cleanup.

Refresh the remaining vendored sources with:

```sh
Rscript tools/vendor_nng_mbedtls.R --force
```
