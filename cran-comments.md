## R CMD check results

* `R CMD check --as-cran --no-manual Rducks_0.1.1.9000.tar.gz`: 0 errors,
  0 warnings, and 2 notes on Ubuntu 24.04 with R 4.6.0.
* The notes are the expected incoming-feasibility note for this development
  submission (including the development version and vignette index) and the
  compiler's `-mno-omit-leaf-frame-pointer` flag.

## Package size

Rducks builds one DuckDB extension against DuckDB's stable C extension API
v1.5.6, so the package does not need a release for each duckdb release.

## Extension signing and files

Installation signs the extension with a key generated for that installation
and keeps only the public key; the private key is never written to disk. At
run time, `rducks_enable()` loads the extension from a local DuckDB extension
repository below `tempdir()`, with DuckDB's signature checks enabled. Examples,
tests and vignettes open connections with `rducks_duckdb_config()`, which keeps
DuckDB's repository records below `tempdir()`. Rducks writes to `~/.duckdb`
only when the user passes `home_registry = TRUE`.
