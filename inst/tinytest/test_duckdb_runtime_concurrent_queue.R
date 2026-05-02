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
  invisible(rducks_register(con, "rducks_queue_plus_one_rc", function(x) x + 1, DOUBLE, DOUBLE, eval_mode = "RC"))
  rducks_enable_inproc(con)

  queued_result <- DBI::dbGetQuery(con, "SELECT sum(rducks_queue_plus_one(i::DOUBLE)) AS x FROM rducks_parallel_range(10::UBIGINT) AS t(i)")
  expect_equal(queued_result$x, sum((0:9) + 1))

  queued_rc_result <- DBI::dbGetQuery(con, "SELECT sum(rducks_queue_plus_one_rc(i::DOUBLE)) AS x FROM rducks_parallel_range(10::UBIGINT) AS t(i)")
  expect_equal(queued_rc_result$x, sum((0:9) + 1))

  final <- rducks_inproc_stats(con)
  expect_true(final$submitted[[1L]] > after$submitted[[1L]])
  expect_equal(final$submitted, final$executed)
  expect_equal(final$timeouts, 0)
})
