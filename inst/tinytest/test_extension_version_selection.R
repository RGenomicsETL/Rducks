library(Rducks)

local({
  current <- getFromNamespace("rducks_installed_duckdb_version", "Rducks")()
  path <- rducks_extension_path()
  build_root <- dirname(dirname(path))
  bundled <- getFromNamespace("rducks_bundled_duckdb_versions", "Rducks")(build_root)

  expect_true(file.exists(path))
  expect_identical(basename(dirname(path)), current)
  expect_identical(bundled, paste0("v1.5.", 0:4))
  expect_identical(rducks_extension_path(current), path)
  expect_identical(rducks_extension_path(sub("^v", "", current)), path)
  expect_error(
    rducks_extension_path("v0.0.0"),
    pattern = "no bundled extension for DuckDB v0.0.0"
  )
  expect_error(
    rducks_extension_path("1.5.4.1"),
    pattern = "must be an exact release"
  )

  con <- duckdb::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  connection_version <- getFromNamespace(
    "rducks_connection_duckdb_version",
    "Rducks"
  )(con)
  expect_identical(connection_version, current)
})
