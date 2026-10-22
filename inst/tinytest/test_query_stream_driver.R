library(Rducks)

local({
  if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE)) {
    exit_file("duckdb/DBI not available")
    return(invisible(NULL))
  }
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit({
    try(rducks_release(con), silent = TRUE)
    try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE)
  }, add = TRUE)
  rducks_enable(con, threads = "single")
  # These callbacks must be rejected before any off-thread R access in the
  # managed scalar driver, even though they remain valid in the serial plan.
  rducks_register_table(con, "driver_r_table", function() data.frame(i = 1L))
  rducks_register_aggregate(con, "driver_r_aggregate",
    update = function(state, x) if (is.null(state)) x else state + x,
    finalize = function(state) state, args = INTEGER, returns = INTEGER)
  rducks_enable_inproc(con, threads = 4L, external_threads = 1L)

  if (!Rducks:::rducks_query_stream_driver_available(con)) {
    expect_error(rducks_query_stream(con, "SELECT 1 AS i"),
      pattern = "require duckdb-r off-main R-source guards")
    expect_equal(DBI::dbGetQuery(con, "SELECT 1 AS i")$i, 1L)
    exit_file("managed driver requires duckdb-r off-main guard capability v2")
    return(invisible(NULL))
  }

  drained <- function() {
    stats <- rducks_inproc_stats(con)
    expect_equal(stats$pending_current, 0)
    expect_equal(stats$running_current, 0)
    expect_equal(stats$timeouts, 0)
  }
  reuse <- function() {
    stream <- rducks_query_stream(con, "SELECT i::INTEGER AS i FROM range(1, 4) t(i)")
    expect_equal(stream$next_batch()$i, 1:3)
    expect_null(stream$next_batch())
    expect_null(stream$next_batch())
    stream$close()
    drained()
  }
  consume <- function(sql) {
    stream <- rducks_query_stream(con, sql)
    on.exit(stream$close(), add = TRUE)
    rows <- 0
    total <- 0
    repeat {
      batch <- stream$next_batch()
      if (is.null(batch)) break
      rows <- rows + nrow(batch)
      total <- total + sum(batch$v)
      if ("i" %in% names(batch)) expect_equal(batch$v, batch$i + 7L)
      expect_true(nrow(batch) <= 2048L)
    }
    c(rows = rows, total = total)
  }
  register_scalar <- function(...) {
    DBI::dbExecute(con, "PRAGMA threads=1")
    on.exit(DBI::dbExecute(con, "PRAGMA threads=4"), add = TRUE)
    rducks_register_scalar_udf(con, ...)
  }

  state <- new.env(parent = emptyenv())
  state$lengths <- integer()
  register_scalar("driver_value", function(x) {
    state$lengths <- c(state$lengths, length(x))
    x + 7L
  }, args = INTEGER, returns = INTEGER, mode = "vectorized", side_effects = TRUE)
  DBI::dbExecute(con, "CREATE TABLE driver_input AS SELECT i::INTEGER AS i FROM range(500000) t(i)")

  # Every task keeps its own destination: scheduler completion order may vary,
  # but each key/value pair, row count, and sum must be identical.
  result <- consume("SELECT i, driver_value(i) AS v FROM driver_input")
  expect_equal(result[["rows"]], 500000)
  expect_equal(result[["total"]], sum(0:499999) + 7 * 500000)
  expect_true(length(state$lengths) > 1L)
  expect_true(max(state$lengths) <= 2048L)
  drained()

  # A blocking native aggregate must keep servicing its final worker callbacks.
  result <- consume("SELECT sum(driver_value(i))::DOUBLE AS v FROM driver_input")
  expect_equal(result[["rows"]], 1)
  expect_equal(result[["total"]], sum(0:499999) + 7 * 500000)
  reuse()

  # Prepare-time constant evaluation also runs on the helper and queues R.
  register_scalar("driver_constant", function(x) x + 1L,
    args = INTEGER, returns = INTEGER, mode = "vectorized")
  stream <- rducks_query_stream(con, "SELECT driver_constant(41::INTEGER) AS v")
  expect_equal(stream$next_batch()$v, 42L)
  stream$close()
  reuse()

  # A long result remains incremental. Recursive close/next/release attempts
  # must fail without invalidating the outer stream's handle or runtime anchor.
  state$rows <- 0L
  state$stream <- NULL
  state$checked <- FALSE
  state$errors <- character()
  register_scalar("driver_reentrant", function(x) {
    state$rows <- state$rows + length(x)
    if (!is.null(state$stream) && !state$checked) {
      actions <- list(state$stream$close, state$stream$next_batch,
        function() rducks_release(con),
        function() rducks_query_stream(con, "SELECT 2"),
        function() DBI::dbGetQuery(con, "SELECT driver_value(1::INTEGER)"))
      state$errors <- vapply(actions, function(action) {
        tryCatch({ action(); "no error" }, error = conditionMessage)
      }, character(1))
      state$checked <- TRUE
    }
    x
  }, args = INTEGER, returns = INTEGER, mode = "vectorized", side_effects = TRUE)
  stream <- rducks_query_stream(con,
    "SELECT driver_reentrant(i::INTEGER) AS i FROM range(10000000) t(i)")
  state$stream <- stream
  for (i in seq_len(1000L)) {
    batch <- stream$next_batch()
    expect_true(!is.null(batch))
    if (state$checked) break
  }
  expect_true(state$checked)
  expect_true(all(grepl("already active|recursive", state$errors)))
  expect_true(state$rows < 10000000L)
  rows_before_close <- state$rows
  stream$close()
  expect_equal(state$rows, rows_before_close, info = "close rejects pending callbacks without evaluating extra R")
  stream$close()
  state$stream <- NULL
  reuse()

  # Both native and R failures may arise while other task requests are queued.
  # The failed stream must join before a new stream is admitted.
  expect_error(consume(paste(
    "SELECT driver_value(i) + CAST(CASE WHEN i = 350000 THEN 'bad' ELSE '0' END AS INTEGER) AS v",
    "FROM driver_input"
  )), pattern = "Conversion|convert|bad")
  reuse()
  for (fuse in c(FALSE, TRUE)) {
    register_scalar("driver_fail", function(x) {
      if (any(x > 300000L)) stop("managed callback failure")
      x
    }, args = INTEGER, returns = INTEGER, mode = "vectorized", coalesce = fuse)
    expect_error(consume("SELECT driver_fail(i) AS v FROM driver_input"), pattern = "failure|marshal|failed")
    reuse()
  }
  expect_error(rducks_query_stream(con, "SELECT * FROM driver_r_table()"), pattern = "R table.*unsupported")
  reuse()
  expect_error(consume("SELECT driver_r_aggregate(i) AS v FROM driver_input"), pattern = "R aggregate.*unsupported")
  reuse()

  # A dropped handle owns its connection until the finalizer cancels and joins.
  local({
    forgotten <- rducks_query_stream(con, "SELECT driver_value(i) AS v FROM driver_input")
    expect_true(!is.null(forgotten$next_batch()))
  })
  invisible(gc())
  reuse()
})
