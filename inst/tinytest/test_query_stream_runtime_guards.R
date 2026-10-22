library(Rducks)

local({
  if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE)) {
    exit_file("duckdb/DBI not available")
    return(invisible(NULL))
  }
  drv <- duckdb::duckdb(config = list(allow_unsigned_extensions = "true", threads = "4"))
  first <- DBI::dbConnect(drv)
  second <- DBI::dbConnect(drv)
  on.exit({
    try(rducks_release(second), silent = TRUE)
    try(rducks_release(first), silent = TRUE)
    try(DBI::dbDisconnect(second), silent = TRUE)
    try(DBI::dbDisconnect(first, shutdown = TRUE), silent = TRUE)
  }, add = TRUE)
  # A caller may LOAD the extension before the first enable. That creates a
  # native runtime without an R bridge, with the scheduler still using workers.
  DBI::dbExecute(first, paste("LOAD", DBI::dbQuoteString(first,
    normalizePath(rducks_extension_path()))))
  rducks_enable(first, threads = "single")
  if (!getFromNamespace("rducks_query_stream_driver_available", "Rducks")(first)) {
    exit_file("duckdb-r off-main R-source guard capability is not available")
    return(invisible(NULL))
  }
  rducks_set_execution_plan(first, rducks_execution_plan("inproc"),
    threads = 2L, external_threads = 1L)

  # A second connection shares the native runtime before it has an R anchor.
  # Its failed configuration calls must not change the scheduler under a live
  # driver, or detach the stream that caused the rejection.
  attached_token <- getFromNamespace("rducks_attached_runtime_token", "Rducks")
  expect_true(is.na(attached_token(second)))
  settings <- function() DBI::dbGetQuery(second,
    "SELECT current_setting('threads') AS threads, current_setting('external_threads') AS external_threads")
  before <- settings()
  stream <- rducks_query_stream(first,
    "SELECT i::INTEGER AS i FROM range(1, 500001) t(i)")
  expect_error(rducks_enable(second, threads = "single"), pattern = "stream")
  expect_error(rducks_set_execution_plan(second, rducks_execution_plan("inproc"),
    threads = 1L, external_threads = 1L), pattern = "stream")
  expect_equal(settings(), before)
  expect_true(is.na(attached_token(second)))
  expect_true(nrow(stream$next_batch()) > 0L)
  stream$close()

  # Configuration becomes available once the stream is closed.
  rducks_enable(second, threads = "single")
  expect_false(is.na(attached_token(second)))
  rducks_release(second)

  # In-memory runtimes keep their catalog connection after the last R anchor
  # is released, but must still close and join an outstanding stream driver.
  rducks_set_execution_plan(first, rducks_execution_plan("inproc"),
    threads = 2L, external_threads = 1L)
  abandoned <- rducks_query_stream(first,
    "SELECT i::INTEGER AS i FROM range(1, 500001) t(i)")
  rducks_release(first)
  rducks_enable(first, threads = "single")
  replacement <- rducks_query_stream(first, "SELECT 42::INTEGER AS answer")
  expect_equal(replacement$next_batch()$answer, 42L)
  replacement$close()
  abandoned$close()

  # File-backed release closes the internal connections before shutdown.
  # Stale R handles must remain safe, and the next database instance must
  # register its own bridge even if its initial scheduler has worker threads.
  local({
    path <- tempfile("rducks-stream-runtime-", fileext = ".duckdb")
    file_con <- NULL
    on.exit({
      if (!is.null(file_con)) {
        try(rducks_release(file_con), silent = TRUE)
        try(DBI::dbDisconnect(file_con, shutdown = TRUE), silent = TRUE)
      }
      unlink(c(path, paste0(path, ".wal")))
    }, add = TRUE)
    connect_file <- function() {
      DBI::dbConnect(duckdb::duckdb(dbdir = path,
        config = list(allow_unsigned_extensions = "true", threads = "4")))
    }
    driver_available <- getFromNamespace("rducks_query_stream_driver_available", "Rducks")
    for (cleanup in c("close", "gc")) {
      file_con <- connect_file()
      rducks_enable(file_con, threads = "single")
      expect_true(driver_available(file_con))
      rducks_set_execution_plan(file_con, rducks_execution_plan("inproc"),
        threads = 2L, external_threads = 1L)
      stale <- rducks_query_stream(file_con,
        "SELECT i::INTEGER AS i FROM range(1, 500001) t(i)")
      expect_true(nrow(stale$next_batch()) > 0L)
      rducks_release(file_con)
      DBI::dbDisconnect(file_con, shutdown = TRUE)
      file_con <- NULL
      if (identical(cleanup, "close")) expect_equal(stale$close(), NULL)
      rm(stale)
      invisible(gc())

      file_con <- connect_file()
      rducks_enable(file_con, threads = "single")
      expect_true(driver_available(file_con))
      rducks_set_execution_plan(file_con, rducks_execution_plan("inproc"),
        threads = 2L, external_threads = 1L)
      reopened <- rducks_query_stream(file_con, "SELECT 42::INTEGER AS answer")
      expect_equal(reopened$next_batch()$answer, 42L)
      reopened$close()
      rducks_release(file_con)
      DBI::dbDisconnect(file_con, shutdown = TRUE)
      file_con <- NULL
    }
  })
})
