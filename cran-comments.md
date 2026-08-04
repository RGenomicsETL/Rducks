## R CMD check results

* `R CMD check --as-cran --no-manual Rducks_0.1.1.9000.tar.gz`: 0 errors,
  0 warnings, and 2 notes on Ubuntu 24.04 with R 4.6.0.
* The notes are the expected incoming-feasibility note for this development
  submission (including the development version and vignette index) and the
  compiler's `-mno-omit-leaf-frame-pointer` flag.

## Package size

Rducks uses DuckDB's exact `C_STRUCT_UNSTABLE` extension ABI. The installed
package contains six separately compiled extension artifacts for DuckDB v1.5.0
through v1.5.5; the 17.9 MB installed footprint is expected and is required to
avoid unsafe ABI fallback between DuckDB releases.
