library(Rducks)

plan <- rducks_execution_plan()
expect_equal(plan$marshalling, "arrow_r")
expect_equal(plan$concurrency, "serial")
expect_equal(plan$plan_id, "arrow_r+serial")
expect_true(plan$reference)
expect_true(plan$implemented)
expect_equal(plan$backend, "single")
expect_equal(plan$serialization, "none")
expect_true(plan$in_process)
expect_true(plan$uses_r_thread)
expect_equal(plan$supported_call_shapes, c("scalar", "vectorized"))

inproc <- rducks_execution_plan("arrow_c", "inproc_concurrent")
expect_equal(inproc$marshalling, "arrow_c")
expect_equal(inproc$concurrency, "inproc_concurrent")
expect_equal(inproc$plan_id, "arrow_c+inproc_concurrent")
expect_false(inproc$reference)
expect_true(inproc$implemented)
expect_equal(inproc$backend, "concurrent_inproc")
expect_equal(inproc$supported_call_shapes, c("scalar", "vectorized"))

ipc <- rducks_execution_plan("arrow_ipc", "multiprocess_parallel")
expect_equal(ipc$serialization, "arrow_ipc")
expect_true(ipc$implemented)
expect_equal(ipc$supported_call_shapes, c("scalar", "vectorized"))
expect_false(ipc$in_process)
expect_true(ipc$uses_r_thread)
expect_equal(ipc$future_options$packages, "Rducks")
expect_silent(Rducks:::rducks_assert_execution_plan_implemented(ipc))

expect_error(
  rducks_execution_plan("arrow_ipc", "serial"),
  "requires concurrency = 'multiprocess_parallel'"
)
expect_error(
  rducks_execution_plan("arrow_r", "multiprocess_parallel"),
  "requires marshalling = 'arrow_ipc'"
)
vectorized_spec <- Rducks:::rducks_registration_spec(
  "vec", function(x) x, INTEGER, INTEGER, mode = "vectorized"
)
expect_silent(
  Rducks:::rducks_validate_execution_plan_for_registration(
    rducks_execution_plan("arrow_c", "serial"), vectorized_spec
  )
)
expect_equal(Rducks:::rducks_plan_native_evaluator_token(rducks_execution_plan("arrow_c", "serial"), "vectorized"), "RCV")

input <- data.frame(x = 1:3, y = c("a", "b", "c"))
expect_error(
  Rducks:::rducks_arrow_ipc_encode(input),
  "requires a nanoarrow_array"
)
native_payload <- Rducks:::rducks_arrow_ipc_encode(nanoarrow::as_nanoarrow_array(input))
expect_true(is.raw(native_payload))
expect_true(length(native_payload) > 0L)
native_roundtrip <- as.data.frame(Rducks:::rducks_arrow_ipc_decode_stream(native_payload))
expect_equal(native_roundtrip, input)
