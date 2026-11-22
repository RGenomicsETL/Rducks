source(file.path("..", "duckdb_version_support.R"), local = TRUE)

check_runtime_policy <- function() {
  root <- tempfile("rducks-ci-runtime-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  description <- file.path(root, "DESCRIPTION")
  write_minimum <- function(imports) {
    writeLines(c("Package: Rducks", paste("Imports:", imports)), description)
  }

  write_minimum("DBI, duckdb (>= 1.10.0), S7")
  expect_identical(rducks_minimum_duckdb_version(root), "v1.10.0")
  expect_identical(rducks_ci_duckdb_package("supported", root), "duckdb@1.10.0")
  expect_identical(rducks_ci_duckdb_package("latest", root), "duckdb")
  expect_identical(rducks_check_ci_duckdb_runtime("v1.10.0", "supported", root), "v1.10.0")
  expect_identical(rducks_check_ci_duckdb_runtime("v1.11.2", "latest", root), "v1.11.2")
  expect_error(
    rducks_check_ci_duckdb_runtime("v1.11.2", "supported", root),
    "requires DuckDB v1.10.0"
  )
  expect_error(
    rducks_check_ci_duckdb_runtime("v1.9.0", "latest", root),
    "older than the minimum v1.10.0"
  )
  expect_error(rducks_check_ci_duckdb_runtime("main", "latest", root), "not a release version")
  expect_error(rducks_ci_duckdb_package("other", root), "arg.*should be one of")
  expect_error(rducks_check_ci_duckdb_runtime("v1.10.0", "other", root), "arg.*should be one of")

  write_minimum("DBI, duckdb, S7")
  expect_error(rducks_ci_duckdb_package("supported", root), "minimum release version")
}

check_runtime_policy()
