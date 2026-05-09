library(Rducks)

local({
  old_dev <- Sys.getenv("RDUCKS_DEV_SURFACES", unset = NA_character_)
  Sys.setenv(RDUCKS_DEV_SURFACES = "true")
  on.exit({
    if (is.na(old_dev)) Sys.unsetenv("RDUCKS_DEV_SURFACES") else Sys.setenv(RDUCKS_DEV_SURFACES = old_dev)
  }, add = TRUE)
  Rducks:::rducks_nng_stop_all_providers(quiet = TRUE)
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit({
    try(Rducks:::rducks_nng_stop_all_providers(quiet = TRUE), silent = TRUE)
    DBI::dbDisconnect(con, shutdown = TRUE)
  }, add = TRUE)
  rducks_enable(con, threads = "single")

  enabled <- DBI::dbGetQuery(con, "SELECT rducks_nng_enabled() AS enabled")$enabled[[1L]]
  version <- DBI::dbGetQuery(con, "SELECT rducks_nng_version() AS nng_version")$nng_version[[1L]]

  expect_true(is.logical(enabled))
  expect_true(enabled)
  expect_true(is.character(version))
  expect_true(nzchar(version))
  expect_true(grepl("^1\\.", version))
  expect_true(DBI::dbGetQuery(con, "SELECT rducks_nng_self_test() AS ok")$ok[[1L]])
})
