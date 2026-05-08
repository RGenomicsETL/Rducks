Sys.setenv(RDUCKS_DEV_SURFACES = "true")
library(Rducks)

local({
  expect_true(Rducks:::rducks_arrow_ipc_mapping_supported(INTEGER))
  expect_equal(Rducks:::rducks_arrow_ipc_unsupported_types(INTEGER), character())
  expect_true(Rducks:::rducks_arrow_ipc_mapping_supported(STRUCT(x = LIST(ENUM(c("red", "blue"))))))
  expect_equal(Rducks:::rducks_arrow_ipc_unsupported_types(MAP(VARCHAR, DECIMAL(10, 2))), character())
  expect_error(Rducks:::rducks_arrow_ipc_mapping_supported("list<i32>"), "constructors")

  payload <- Rducks:::rducks_arrow_ipc_encode(nanoarrow::as_nanoarrow_array(data.frame(x = 1:3)))
  expect_true(is.raw(payload))
  expect_equal(as.data.frame(Rducks:::rducks_arrow_ipc_decode_stream(payload))$x, 1:3)
  expect_error(Rducks:::rducks_arrow_ipc_decode_array(raw()), "record batch|Arrow|IPC|schema|Invalid|read")
  expect_error(Rducks:::rducks_arrow_ipc_decode_array(as.raw(c(1L, 2L, 3L, 4L))), "record batch|Arrow|IPC|schema|Invalid|read")

  plan <- rducks_execution_plan("arrow_ipc", "multiprocess_parallel")
  expect_equal(plan$engine_id, "ipc_nng_pool")
  expect_true(plan$implemented)
  expect_equal(plan$supported_call_shapes, c("scalar", "vectorized"))
  expect_silent(Rducks:::rducks_assert_execution_plan_implemented(plan))
})
