## R CMD check results

Check results for the submitted tarball are to be filled in by the maintainer
after running `R CMD check --as-cran` on the final build. Two NOTEs are known:

* The incoming-feasibility NOTE (new submission and, for a development
  version, the version number).
* A compiler-flag NOTE about `-mno-omit-leaf-frame-pointer`, which comes from
  the R installation's compiler settings, not from Rducks.

## Design and installation

* Rducks builds one DuckDB extension against DuckDB's stable C extension API
  v1.5.6. The same binary loads in DuckDB 2.0.0 and later, so the package
  needs no new release for each DuckDB release. The package requires
  `duckdb (>= 2.0.0)`.
* Installation signs the extension with a key generated for that installation.
  Only the public key is kept; the private key is never written to disk.
* At run time, `rducks_enable()` loads the extension from a local DuckDB
  extension repository below `tempdir()`, with DuckDB's signature checks
  enabled.
* Rducks writes nothing to the user's home directory unless the user passes
  `home_registry = TRUE`. Examples, tests and vignettes open connections with
  `rducks_duckdb_config()`, which keeps DuckDB's repository records below
  `tempdir()`.

## CPU use

* Installation builds the vendored NNG and Mbed TLS with at most two parallel
  jobs. The environment variable `RDUCKS_BUILD_JOBS` changes this for local
  builds.
* Examples, tests and vignettes that run by default use at most two DuckDB
  threads. A test that needs more concurrency runs only under
  `tinytest::at_home()`.
