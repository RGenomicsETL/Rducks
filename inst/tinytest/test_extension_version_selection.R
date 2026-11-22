library(Rducks)

local({
  path <- rducks_extension_path()
  expect_true(file.exists(path))
  expect_identical(basename(path), "rducks.duckdb_extension")
  expect_identical(rducks_extension_capi_version(path), "v1.5.6")

  bad <- tempfile(fileext = ".duckdb_extension")
  on.exit(unlink(bad), add = TRUE)
  writeBin(as.raw(seq_len(16L)), bad)
  expect_error(rducks_extension_capi_version(bad), pattern = "too small")

  footer <- readBin(path, "raw", n = file.size(path))
  abi_field <- length(footer) - 512L + 3L * 32L + seq_len(32L)
  footer[abi_field] <- c(charToRaw("C_STRUCT_UNSTABLE"), as.raw(rep(0L, 15L)))
  writeBin(footer, bad)
  expect_error(rducks_extension_capi_version(bad), pattern = "not a stable C API extension")

  con <- duckdb::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  expect_true(getFromNamespace("rducks_assert_engine_supports_extension", "Rducks")(con, path))

  future <- footer
  future[abi_field] <- c(charToRaw("C_STRUCT"), as.raw(rep(0L, 24L)))
  version_field <- length(future) - 512L + 5L * 32L + seq_len(32L)
  future[version_field] <- c(charToRaw("v99.0.0"), as.raw(rep(0L, 25L)))
  writeBin(future, bad)
  expect_error(
    getFromNamespace("rducks_assert_engine_supports_extension", "Rducks")(con, bad),
    pattern = "needs DuckDB v99.0.0 or later"
  )
})
