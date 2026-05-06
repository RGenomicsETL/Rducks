library(Rducks)

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  current <- rducks_current_execution_plan(con)
  expect_equal(current$plan_id, "arrow_r+serial")
  expect_equal(current$engine_id, "arrow_r_serial")
  expect_equal(rducks_native_execution_backend(con), "single")
  expect_equal(Rducks:::rducks_as_execution_plan("arrow_c_direct_serial")$plan_id, "arrow_c+serial")
  expect_equal(Rducks:::rducks_as_execution_plan("ipc_future_pool")$plan_id, "arrow_ipc+multiprocess_parallel")

  rducks_set_execution_plan(con, rducks_execution_plan("arrow_c", "serial"))
  current <- rducks_current_execution_plan(con)
  expect_equal(current$plan_id, "arrow_c+serial")
  expect_equal(current$engine_id, "arrow_c_direct_serial")

  reg <- rducks_register(con, "plan_plus_one", function(x) x + 1L, INTEGER, INTEGER)
  expect_equal(reg$execution_plan$marshalling, "arrow_c")
  expect_equal(reg$execution_plan$plan_id, "arrow_c+serial")
  result <- DBI::dbGetQuery(con, "SELECT plan_plus_one(41::INTEGER) AS x")
  expect_equal(result$x, 42L)

  reg_vec <- rducks_register(con, "plan_vec", function(x) x + 1L, INTEGER, INTEGER, mode = "vectorized")
  expect_equal(reg_vec$execution_plan$marshalling, "arrow_c")
  result_vec <- DBI::dbGetQuery(con, "SELECT plan_vec(i::INTEGER) AS x FROM range(3) t(i)")
  expect_equal(result_vec$x, 1:3)
  expect_equal(rducks_explain_udf(con, "plan_vec")$evaluator, "RCV")

  rducks_set_execution_plan(con, rducks_execution_plan("arrow_r", "serial"))
  reg_r <- rducks_register(con, "plan_r_plus_one", function(x) x + 1L, INTEGER, INTEGER)
  expect_equal(reg_r$execution_plan$marshalling, "arrow_r")

  rducks_set_execution_plan(con, rducks_execution_plan("arrow_c", "serial"))
  rducks_enable_inproc(con)
  expect_equal(rducks_current_execution_plan(con)$plan_id, "arrow_c+inproc_concurrent")
  expect_equal(rducks_native_execution_backend(con), "concurrent_inproc")
  rducks_disable_inproc(con)
  expect_equal(rducks_current_execution_plan(con)$plan_id, "arrow_c+serial")
  expect_equal(rducks_native_execution_backend(con), "single")

  before_threads <- Rducks:::rducks_connection_threads(con)
  before_external_threads <- Rducks:::rducks_connection_external_threads(con)
  bad_plan <- rducks_execution_plan("arrow_c", "serial")
  bad_plan$backend <- "invalid_backend_for_rollback_test"
  new_threads <- if (identical(before_threads, 1L)) 2L else 1L
  new_external_threads <- if (new_threads > 1L && identical(before_external_threads, 1L)) new_threads else 1L
  expect_error(
    rducks_set_execution_plan(con, bad_plan, threads = new_threads, external_threads = new_external_threads),
    "unsupported Rducks execution backend"
  )
  expect_equal(Rducks:::rducks_connection_threads(con), before_threads)
  expect_equal(Rducks:::rducks_connection_external_threads(con), before_external_threads)
  expect_equal(rducks_current_execution_plan(con)$plan_id, "arrow_c+serial")

  old_future_plan <- future::plan()
  on.exit(future::plan(old_future_plan), add = TRUE)
  future::plan(future::multisession, workers = 1)

  rducks_set_execution_plan(con, rducks_execution_plan("arrow_ipc", "multiprocess_parallel"))
  reg_ipc <- rducks_register(
    con, "plan_ipc_vec", function(x) x + 1L,
    INTEGER, INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  )
  expect_equal(reg_ipc$execution_plan$plan_id, "arrow_ipc+multiprocess_parallel")
  result_ipc <- DBI::dbGetQuery(con, "SELECT plan_ipc_vec(i::INTEGER) AS x FROM range(3) t(i)")
  expect_equal(result_ipc$x, 1:3)
  explain_ipc <- rducks_explain_udf(con, "plan_ipc_vec")
  expect_equal(explain_ipc$native_marshalling, "arrow_ipc")
  expect_equal(explain_ipc$evaluator, "RIPC")
  expect_true(explain_ipc$arrow_ipc_chunks >= 1)
  expect_equal(explain_ipc$arrow_r_chunks, 0)
  expect_equal(explain_ipc$arrow_c_chunks, 0)
})
