library(Rducks)

local({
  plan <- rducks_execution_plan("inproc")
  expect_equal(plan$marshalling, "direct")
  expect_equal(plan$concurrency, "inproc_concurrent")
  expect_true(plan$implemented)
  expect_error(rducks_execution_plan("ipc"), "inproc")
})
