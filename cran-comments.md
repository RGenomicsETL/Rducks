## R CMD check results

* `R CMD check --as-cran --no-manual Rducks_0.1.1.9000.tar.gz`: 0 errors,
  0 warnings, and 2 notes on Ubuntu 24.04 with R 4.6.0.
* The notes are the expected incoming-feasibility note for this development
  submission (including the development version and vignette index) and the
  compiler's `-mno-omit-leaf-frame-pointer` flag.

## Package size

Rducks builds one DuckDB extension against DuckDB's stable C extension API
v1.5.6. The same artifact loads on duckdb 1.5.6 and later, so the package does
not need a release for each duckdb release.
