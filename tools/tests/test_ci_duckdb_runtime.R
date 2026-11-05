source(file.path("..", "duckdb_version_support.R"), local = TRUE)

check_runtime_policy <- function() {
  root <- tempfile("rducks-ci-runtime-")
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  path <- file.path(root, "tools", "ext", "duckdb_capi")
  dir.create(path, recursive = TRUE)
  manifest <- file.path(path, "versions.txt")
  versions <- c("v1.9.0", "v1.5.6", "v1.10.0")
  writeLines(c("# Bundled engine versions", versions), manifest)

  expect_identical(rducks_ci_duckdb_package("supported", root), "duckdb@1.10.0")
  expect_identical(rducks_ci_duckdb_package("latest", root), "duckdb")
  expect_identical(
    rducks_check_ci_duckdb_runtime("v1.10.0", "supported", root),
    "v1.10.0"
  )
  expect_identical(
    rducks_check_ci_duckdb_runtime("v1.9.0", "latest", root),
    "v1.9.0"
  )
  expect_error(
    rducks_check_ci_duckdb_runtime("v1.9.0", "supported", root),
    "requires DuckDB v1.10.0"
  )
  expect_error(
    rducks_check_ci_duckdb_runtime("v1.10.1", "latest", root),
    "not bundled for the latest runtime check"
  )
  expect_error(
    rducks_check_ci_duckdb_runtime("v1.10.1", "supported", root),
    "not bundled for the supported runtime check"
  )
  expect_error(rducks_ci_duckdb_package("other", root), "arg.*should be one of")
  expect_error(
    rducks_check_ci_duckdb_runtime("v1.10.0", "other", root),
    "arg.*should be one of"
  )

  writeLines(c("v2.0.1", versions), manifest)
  expect_identical(rducks_ci_duckdb_package("supported", root), "duckdb@2.0.1")
  expect_identical(
    rducks_check_ci_duckdb_runtime("v2.0.1", "latest", root),
    "v2.0.1"
  )
  expect_error(
    rducks_check_ci_duckdb_runtime("v1.10.0", "supported", root),
    "requires DuckDB v2.0.1"
  )

  writeLines(character(), manifest)
  expect_error(rducks_ci_duckdb_package("supported", root), "manifest is empty")
  expect_error(
    rducks_check_ci_duckdb_runtime("v2.0.1", "latest", root),
    "manifest is empty"
  )
}

check_runtime_policy()
