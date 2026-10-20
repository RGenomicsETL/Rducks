library(Rducks)

# In-process concurrent plan: pending chunks of the same vectorized UDF are
# coalesced into one R call on the main R thread. The R function must then see
# inputs longer than one DuckDB vector, and results, NULL handling, and errors
# must match the serial evaluation exactly.
local({
  if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE)) {
    exit_file("duckdb/DBI not available")
  }
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  on.exit(rducks_release(con), add = TRUE)
  q1 <- function(sql) DBI::dbGetQuery(con, sql)[[1L]][[1L]]
  plan <- rducks_execution_plan("inproc")

  call_lengths <- integer()
  rducks_register_scalar_udf(con, "bt_dbl", function(x) { call_lengths <<- c(call_lengths, length(x)); x * 2 },
    args = list(DOUBLE), returns = DOUBLE, mode = "vectorized", side_effects = TRUE)
  rducks_register_scalar_udf(con, "bt_point", function(x, y) list(x = x, y = y),
    args = list(DOUBLE, DOUBLE), returns = STRUCT(x = DOUBLE, y = DOUBLE), mode = "vectorized")
  rducks_register_scalar_udf(con, "bt_blob", function(x) lapply(x, function(v) as.raw(c(0x01, as.integer(v) %% 256L))),
    args = list(DOUBLE), returns = BLOB, mode = "vectorized")
  rducks_register_scalar_udf(con, "bt_chr", function(s, j) paste0(s, "-", j),
    args = list(VARCHAR, INTEGER), returns = VARCHAR, mode = "vectorized")
  rducks_register_scalar_udf(con, "bt_throw", function(x) if (any(x > 900000)) stop("boom") else x,
    args = list(DOUBLE), returns = DOUBLE, mode = "vectorized")
  rducks_register_scalar_udf(con, "bt_special", function(x) ifelse(is.na(x), -1, x),
    args = list(DOUBLE), returns = DOUBLE, mode = "vectorized", null_handling = "special")

  # 1M rows with NULLs: enough chunks that the main thread drains while
  # several worker-thread requests are pending.
  DBI::dbExecute(con, "CREATE TABLE src AS SELECT i, CASE WHEN i % 7 = 0 THEN NULL ELSE i * 0.5 END AS v, CASE WHEN i % 11 = 0 THEN NULL ELSE 'v' || i END AS s, (i % 1000)::INTEGER AS j FROM range(1000000) t(i)")
  serial <- list(
    dbl = DBI::dbGetQuery(con, "SELECT i, bt_dbl(v) AS r FROM src ORDER BY i"),
    point = DBI::dbGetQuery(con, "SELECT i, bt_point(v, v * 3) AS r FROM src ORDER BY i"),
    blob = DBI::dbGetQuery(con, "SELECT i, bt_blob(v) AS r FROM src ORDER BY i"),
    chr = DBI::dbGetQuery(con, "SELECT i, bt_chr(s, j) AS r FROM src ORDER BY i"),
    special = DBI::dbGetQuery(con, "SELECT i, bt_special(v) AS r FROM src ORDER BY i")
  )
  call_lengths <- integer()

  rducks_set_execution_plan(con, plan, threads = 8L, external_threads = 1L)
  on.exit(try(rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L), silent = TRUE), add = TRUE)
  concurrent <- list(
    dbl = DBI::dbGetQuery(con, "SELECT i, bt_dbl(v) AS r FROM src ORDER BY i"),
    point = DBI::dbGetQuery(con, "SELECT i, bt_point(v, v * 3) AS r FROM src ORDER BY i"),
    blob = DBI::dbGetQuery(con, "SELECT i, bt_blob(v) AS r FROM src ORDER BY i"),
    chr = DBI::dbGetQuery(con, "SELECT i, bt_chr(s, j) AS r FROM src ORDER BY i"),
    special = DBI::dbGetQuery(con, "SELECT i, bt_special(v) AS r FROM src ORDER BY i")
  )
  for (nm in names(serial)) expect_identical(concurrent[[nm]], serial[[nm]], info = nm)
  # coalescing happened: some R calls covered more than one DuckDB vector
  expect_true(length(call_lengths) > 0L)
  expect_true(max(call_lengths) > 2048L, info = sprintf("max call length %d", max(call_lengths)))
  expect_identical(sum(call_lengths), q1("SELECT count(v)::INTEGER FROM src"))
  # an error in one coalesced call fails the query, not silently part of it
  expect_error(q1("SELECT sum(bt_throw(i * 1.0)) FROM src"), pattern = "boom|marshal error")
  # counters keep balance after batches
  stats <- rducks_inproc_stats(con)
  expect_identical(stats$pending_current, 0)
  expect_identical(stats$running_current, 0)
  expect_identical(stats$submitted, stats$executed)
})
