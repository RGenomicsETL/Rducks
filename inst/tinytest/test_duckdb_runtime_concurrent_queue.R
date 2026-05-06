library(Rducks)

rducks_test_stress_concurrency <- function() {
  tolower(Sys.getenv("RDUCKS_STRESS_CONCURRENCY", "false")) %in% c("1", "true", "yes")
}

rducks_test_duckdb_threads <- function(default = 8L) {
  threads <- suppressWarnings(as.integer(Sys.getenv("RDUCKS_TEST_DUCKDB_THREADS", as.character(default))))
  if (length(threads) != 1L || is.na(threads) || threads < 1L) threads <- default
  max(1L, threads)
}

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  before <- rducks_inproc_stats(con)
  expect_equal(before$submitted, 0)
  expect_equal(before$executed, 0)
  expect_equal(before$timeouts, 0)
  expect_equal(before$pending_current, 0)
  expect_equal(before$pending_max, 0)
  expect_equal(before$running_current, 0)
  expect_equal(before$running_max, 0)

  self_test <- rducks_inproc_self_test(con, 3)
  expect_equal(self_test, 3)

  after <- rducks_inproc_stats(con)
  expect_equal(after$submitted, 3)
  expect_equal(after$executed, 3)
  expect_equal(after$timeouts, 0)
  expect_equal(after$pending_current, 0)
  expect_true(after$pending_max >= 1)
  expect_equal(after$running_current, 0)
  expect_true(after$running_max >= 1)

  invisible(rducks_register(con, "rducks_queue_plus_one", function(x) x + 1, DOUBLE, DOUBLE))
  invisible(rducks_register(con, "rducks_queue_plus_one_vec", function(x) x + 1, DOUBLE, DOUBLE,
                            mode = "vectorized", side_effects = TRUE))
  rducks_enable_inproc(con)
  expect_equal(rducks_current_execution_plan(con)$plan_id, "arrow_r+inproc_concurrent")

  queued_result <- DBI::dbGetQuery(con, "SELECT sum(rducks_queue_plus_one(i::DOUBLE)) AS x FROM rducks_parallel_range(10::UBIGINT) AS t(i)")
  expect_equal(queued_result$x, sum((0:9) + 1))

  queued_vec_result <- DBI::dbGetQuery(con, "SELECT sum(rducks_queue_plus_one_vec(i::DOUBLE)) AS x FROM rducks_parallel_range(10::UBIGINT) AS t(i)")
  expect_equal(queued_vec_result$x, sum((0:9) + 1))

  final <- rducks_inproc_stats(con)
  expect_true(final$submitted[[1L]] >= after$submitted[[1L]])
  expect_equal(final$submitted, final$executed)
  expect_equal(final$timeouts, 0)
})

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  rducks_set_execution_plan(con, rducks_execution_plan("arrow_c", "serial"))

  invisible(rducks_register(con, "rducks_queue_plus_one_c", function(x) x + 1, DOUBLE, DOUBLE))
  invisible(rducks_register(con, "rducks_queue_plus_one_c_vec", function(x) x + 1, DOUBLE, DOUBLE,
                            mode = "vectorized", side_effects = TRUE))
  rducks_enable_inproc(con)
  expect_equal(rducks_current_execution_plan(con)$plan_id, "arrow_c+inproc_concurrent")

  before <- rducks_inproc_stats(con)
  queued_c_result <- DBI::dbGetQuery(con, "SELECT sum(rducks_queue_plus_one_c(i::DOUBLE)) AS x FROM rducks_parallel_range(10::UBIGINT) AS t(i)")
  expect_equal(queued_c_result$x, sum((0:9) + 1))
  queued_c_vec_result <- DBI::dbGetQuery(con, "SELECT sum(rducks_queue_plus_one_c_vec(i::DOUBLE)) AS x FROM rducks_parallel_range(10::UBIGINT) AS t(i)")
  expect_equal(queued_c_vec_result$x, sum((0:9) + 1))
  explain_c <- rducks_explain_udf(con, "rducks_queue_plus_one_c")
  expect_equal(explain_c$evaluator, "RC")
  expect_true(explain_c$dispatch_chunks >= 1)
  expect_true(explain_c$direct_chunks >= 1)
  expect_true(explain_c$arrow_c_chunks >= 1)
  expect_equal(explain_c$arrow_r_chunks, 0)
  explain_c_vec <- rducks_explain_udf(con, "rducks_queue_plus_one_c_vec")
  expect_equal(explain_c_vec$evaluator, "RCV")
  expect_true(explain_c_vec$arrow_c_chunks >= 1)
  expect_equal(explain_c_vec$arrow_r_chunks, 0)
  final <- rducks_inproc_stats(con)
  expect_true(final$submitted[[1L]] >= before$submitted[[1L]])
  expect_equal(final$submitted, final$executed)
  expect_equal(final$timeouts, 0)
})

if (rducks_test_stress_concurrency()) local({
  threads <- rducks_test_duckdb_threads()
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  invisible(rducks_register(con, "rducks_stress_plus_one", function(x) x + 1, DOUBLE, DOUBLE,
                            mode = "vectorized", side_effects = TRUE))
  rducks_enable_inproc(con, threads = threads, external_threads = 1L)

  before <- rducks_inproc_stats(con)
  out <- DBI::dbGetQuery(
    con,
    "SELECT sum(rducks_stress_plus_one(i::DOUBLE)) AS x FROM rducks_parallel_range(4096::UBIGINT) AS t(i)"
  )
  expect_equal(out$x, sum((0:4095) + 1))

  final <- rducks_inproc_stats(con)
  expect_true(final$submitted[[1L]] > before$submitted[[1L]])
  expect_equal(final$submitted, final$executed)
  expect_equal(final$timeouts, 0)
})
