library(Rducks)

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  current <- rducks_current_execution_plan(con)
  expect_equal(current$plan_id, "arrow_r+serial")

  rducks_set_execution_plan(con, rducks_execution_plan("arrow_c", "serial"))
  current <- rducks_current_execution_plan(con)
  expect_equal(current$plan_id, "arrow_c+serial")

  reg <- rducks_register(con, "plan_plus_one", function(x) x + 1L, INTEGER, INTEGER)
  expect_equal(reg$execution_plan$marshalling, "arrow_c")
  expect_equal(reg$execution_plan$plan_id, "arrow_c+serial")
  result <- DBI::dbGetQuery(con, "SELECT plan_plus_one(41::INTEGER) AS x")
  expect_equal(result$x, 42L)

  reg_vec <- rducks_register(con, "plan_vec", function(x) x + 1L, INTEGER, INTEGER, mode = "vectorized")
  expect_equal(reg_vec$execution_plan$plan_id, "arrow_c+serial")
  result_vec <- DBI::dbGetQuery(con, "SELECT plan_vec(i::INTEGER) AS x FROM range(3) t(i)")
  expect_equal(result_vec$x, 1:3)
  explain_vec <- rducks_explain_udf(con, "plan_vec")
  expect_equal(explain_vec$native_marshalling, "arrow_c")
  expect_equal(explain_vec$evaluator, "RCV")
  expect_true(explain_vec$arrow_c_chunks >= 1)
  expect_equal(explain_vec$arrow_r_chunks, 0)

  rducks_set_execution_plan(con, rducks_execution_plan("arrow_r", "serial"))
  reg_r <- rducks_register(con, "plan_r_plus_one", function(x) x + 1L, INTEGER, INTEGER)
  expect_equal(reg_r$execution_plan$marshalling, "arrow_r")

  rducks_set_execution_plan(con, rducks_execution_plan("arrow_c", "serial"))
  rducks_enable_inproc(con)
  expect_equal(rducks_current_execution_plan(con)$plan_id, "arrow_c+inproc_concurrent")
  rducks_disable_inproc(con)
  expect_equal(rducks_current_execution_plan(con)$plan_id, "arrow_c+serial")

  expect_error(
    rducks_set_execution_plan(con, rducks_execution_plan("arrow_ipc", "multiprocess_parallel")),
    "not implemented yet"
  )
})
