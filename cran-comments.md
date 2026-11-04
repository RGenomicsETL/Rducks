## R CMD check results

* `R CMD check --as-cran --no-manual Rducks_0.1.1.9000.tar.gz`: 0 errors,
  0 warnings, and 2 notes on Ubuntu 24.04 with R 4.6.0.
* The notes are the expected incoming-feasibility note for this development
  submission (including the development version and vignette index) and the
  compiler's `-mno-omit-leaf-frame-pointer` flag.

## Package size

Rducks bundles one separately compiled extension artifact per supported DuckDB
engine release: eight artifacts of about 2.9 MB each, for DuckDB v1.5.0 through
v1.5.6 (exact `C_STRUCT_UNSTABLE` ABI) and v2.0.0 (stable V1 `C_STRUCT` ABI
pinned to C API v1.5.6). The roughly 25 MB installed footprint (measured on
Ubuntu 24.04, R 4.3.3) is expected and avoids unsafe ABI fallback between
DuckDB releases.
