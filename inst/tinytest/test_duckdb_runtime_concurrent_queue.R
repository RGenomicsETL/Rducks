library(Rducks)

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  before <- rducks_inproc_stats(con)
  expect_equal(before$submitted, 0)
  expect_equal(before$executed, 0)
  expect_equal(before$timeouts, 0)

  self_test <- rducks_inproc_self_test(con, 3)
  expect_equal(self_test, 3)

  after <- rducks_inproc_stats(con)
  expect_equal(after$submitted, 3)
  expect_equal(after$executed, 3)
  expect_equal(after$timeouts, 0)

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
  expect_true(final$submitted[[1L]] > after$submitted[[1L]])
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
  explain_c_vec <- rducks_explain_udf(con, "rducks_queue_plus_one_c_vec")
  expect_equal(explain_c_vec$evaluator, "RCV")
  expect_true(explain_c_vec$queued_chunks >= 1)
  expect_true(explain_c_vec$arrow_c_chunks >= 1)
  expect_equal(explain_c_vec$arrow_r_chunks, 0)
  final <- rducks_inproc_stats(con)
  expect_true(final$submitted[[1L]] > before$submitted[[1L]])
  expect_equal(final$submitted, final$executed)
  expect_equal(final$timeouts, 0)
})
