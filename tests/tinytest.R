Sys.setenv(RDUCKS_DEV_SURFACES = "true")
`%||%` <- if (exists("%||%", envir = baseenv(), mode = "function", inherits = FALSE)) {
  get("%||%", envir = baseenv(), mode = "function", inherits = FALSE)
} else {
  function(x, y) if (is.null(x)) y else x
}
library(Rducks)
if (requireNamespace("tinytest", quietly = TRUE)) {
  # A development version (four components) also runs the tests that need
  # more than two threads; a release version, as on CRAN, does not.
  at_home <- length(unclass(utils::packageVersion("Rducks"))[[1L]]) == 4L
  # duckdb 2.0.1 can wait forever when R code runs under a query and a
  # connection is finalized there (duckdb/duckdb-r#3086). A release version
  # skips the tests that open a DuckDB connection with exactly that version.
  if (!at_home && utils::packageVersion("duckdb") == "2.0.1") {
    Sys.setenv(RDUCKS_SKIP_DUCKDB_TESTS = "true")
  }
  tinytest::test_package("Rducks", at_home = at_home)
}
