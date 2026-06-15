# Vendored native dependencies

Rducks vendors only NNG and Mbed TLS for the native worker transport.

Refresh the remaining vendored sources with:

```sh
Rscript tools/vendor_nng_mbedtls.R --force
```
