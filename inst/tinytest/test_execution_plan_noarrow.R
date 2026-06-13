library(Rducks)

local({
  plan <- rducks_execution_plan("inproc")
  expect_equal(plan$marshalling, "direct")
  expect_equal(plan$concurrency, "inproc_concurrent")
  expect_true(plan$implemented)

  ipc <- rducks_execution_plan("ipc")
  expect_equal(ipc$marshalling, "wire")
  expect_equal(ipc$concurrency, "multiprocess_parallel")
  expect_equal(ipc$engine_id, "ipc_nng_pool")
  expect_error(rducks_execution_plan("nope"))
})
