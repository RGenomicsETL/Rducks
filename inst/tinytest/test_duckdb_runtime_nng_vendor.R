library(Rducks)

local({
  Sys.setenv(RDUCKS_DEV_SURFACES = "true")
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  enabled <- DBI::dbGetQuery(con, "SELECT rducks_nng_enabled() AS enabled")$enabled[[1L]]
  version <- DBI::dbGetQuery(con, "SELECT rducks_nng_version() AS nng_version")$nng_version[[1L]]

  expect_true(is.logical(enabled))
  expect_true(is.character(version))
  expect_true(nzchar(version))

  if (isTRUE(enabled)) {
    expect_true(grepl("^1\\.", version))
    expect_true(DBI::dbGetQuery(con, "SELECT rducks_nng_self_test() AS ok")$ok[[1L]])
  } else {
    expect_equal(version, "disabled")
  }
})
