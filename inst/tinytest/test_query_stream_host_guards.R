library(Rducks)

local({
  if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE)) {
    exit_file("duckdb/DBI not available")
    return(invisible(NULL))
  }
  drv <- duckdb::duckdb(environment_scan = TRUE,
    config = list(allow_unsigned_extensions = "true"))
  con <- DBI::dbConnect(drv)
  on.exit({
    try(rducks_release(con), silent = TRUE)
    try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE)
  }, add = TRUE)
  rducks_enable(con, threads = "single")
  if (!getFromNamespace("rducks_query_stream_driver_available", "Rducks")(con)) {
    exit_file("duckdb-r off-main R-source guard capability is not available")
    return(invisible(NULL))
  }
  rducks_set_execution_plan(con, rducks_execution_plan("inproc"),
    threads = 2L, external_threads = 1L)

  # Replacement scans belong to the database, so an extension-owned native
  # connection encounters them too. Reject before even installing an R symbol.
  expect_error(rducks_query_stream(con,
    "SELECT * FROM rducks_missing_host_source_guard"),
    pattern = "environment replacement scan.*recorded thread")

  # A persistent relational view retains the R-backed table function even
  # though caller-local duckdb_register() views are invisible to the driver.
  relation <- getFromNamespace("rel_from_df", "duckdb")(
    con, data.frame(i = 1:4))
  getFromNamespace("rel_to_view", "duckdb")(
    relation, "main", "rducks_host_dataframe_guard", FALSE)
  expect_equal(DBI::dbGetQuery(con, "SELECT * FROM rducks_host_dataframe_guard")$i, 1:4)
  expect_error(rducks_query_stream(con,
    "SELECT * FROM rducks_host_dataframe_guard"),
    pattern = "R data-frame binding.*recorded thread")
  DBI::dbExecute(con, "DROP VIEW rducks_host_dataframe_guard")

  if (requireNamespace("arrow", quietly = TRUE)) {
    duckdb::duckdb_register_arrow(con, "rducks_host_arrow_guard",
      arrow::Table$create(data.frame(i = 1:4)))
    on.exit(try(duckdb::duckdb_unregister_arrow(con, "rducks_host_arrow_guard"),
      silent = TRUE), add = TRUE, after = FALSE)
    expect_equal(DBI::dbGetQuery(con, "SELECT * FROM rducks_host_arrow_guard")$i, 1:4)
    expect_error(rducks_query_stream(con,
      "SELECT * FROM rducks_host_arrow_guard"),
      pattern = "Arrow replacement scan.*recorded thread")
    duckdb::duckdb_unregister_arrow(con, "rducks_host_arrow_guard")
  }

  # Failed binding joins the driver and leaves the internal connection reusable.
  stream <- rducks_query_stream(con, "SELECT 42::INTEGER AS answer")
  expect_equal(stream$next_batch()$answer, 42L)
  stream$close()
})
