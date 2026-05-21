if (!requireNamespace("duckdb", quietly = TRUE)) {
  exit_file("duckdb not available")
}

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  on.exit(setTimeLimit(cpu = Inf, elapsed = Inf, transient = FALSE), add = TRUE)

  old_dev <- Sys.getenv("RDUCKS_DEV_SURFACES", unset = NA_character_)
  Sys.setenv(RDUCKS_DEV_SURFACES = "true")
  on.exit({
    if (is.na(old_dev)) Sys.unsetenv("RDUCKS_DEV_SURFACES") else Sys.setenv(RDUCKS_DEV_SURFACES = old_dev)
  }, add = TRUE)

  rducks_enable(con)

  setTimeLimit(elapsed = 0.3, transient = FALSE)
  interrupted <- tryCatch(
    {
      rducks_inproc_self_test(con, 1000000L)
      NULL
    },
    error = function(e) e,
    finally = setTimeLimit(cpu = Inf, elapsed = Inf, transient = FALSE)
  )

  expect_true(inherits(interrupted, "error"))
  expect_true(grepl("queued scalar UDF interrupted by user|reached elapsed time limit", conditionMessage(interrupted)))
  expect_equal(DBI::dbGetQuery(con, "SELECT 1 AS ok")$ok, 1)

  stats <- rducks_inproc_stats(con)
  expect_equal(stats$pending_current, 0)
  expect_equal(stats$running_current, 0)
  expect_true(stats$submitted[[1L]] >= stats$executed[[1L]])
  expect_true(stats$submitted[[1L]] - stats$executed[[1L]] <= 1)
})
