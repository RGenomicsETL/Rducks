library(Rducks)

plan <- Rducks:::rducks_scalar_execution_plan()
expect_equal(plan$concurrency, "serial")
expect_equal(plan$backend, "single")
expect_equal(plan$serialization, "none")
expect_true(plan$in_process)
expect_true(plan$uses_r_thread)

serialized <- Rducks:::rducks_scalar_execution_plan(
  concurrency = "chunk_concurrent",
  backend = "serialized",
  serialization = "arrow_ipc"
)
expect_equal(serialized$concurrency, "chunk_concurrent")
expect_false(serialized$in_process)
expect_false(serialized$uses_r_thread)

expect_error(
  Rducks:::rducks_scalar_execution_plan(concurrency = "chunk_concurrent", backend = "single"),
  "requires a concurrent or serialized backend"
)
expect_error(
  Rducks:::rducks_scalar_execution_plan(backend = "serialized", serialization = "none"),
  "requires serialization = 'arrow_ipc'"
)
expect_error(
  Rducks:::rducks_scalar_execution_plan(backend = "single", serialization = "arrow_ipc"),
  "reserved for serialized/out-of-process"
)

input <- data.frame(x = 1:3, y = c("a", "b", "c"))
payload <- Rducks:::rducks_arrow_ipc_encode(input)
expect_true(is.raw(payload))
expect_true(length(payload) > 0L)
roundtrip <- as.data.frame(Rducks:::rducks_arrow_ipc_decode_stream(payload))
expect_equal(roundtrip, input)
