library(Rducks)

if (requireNamespace("mirai", quietly = TRUE)) {
  local({
    provider <- Rducks:::rducks_mirai_provider(workers = 1L)
    provider$start()
    on.exit(provider$stop(), add = TRUE)

    input_array <- nanoarrow::as_nanoarrow_array(data.frame(arg1 = 1:4))
    input_payload <- Rducks:::rducks_arrow_ipc_encode(input_array)
    output_schema_spec <- Rducks:::rducks_arrow_schema_to_spec(
      nanoarrow::infer_nanoarrow_schema(data.frame(result = integer()))
    )

    provider$register_udf(
      udf_id = "plus_one",
      udf_name = "plus_one",
      fun = function(x) x + 1L,
      arg_types = list(INTEGER),
      return_type = INTEGER,
      mode = "vectorized",
      null_handling = "default",
      exception_handling = "rethrow",
      output_schema_spec = output_schema_spec
    )

    task_id <- provider$submit(
      udf_id = "plus_one",
      chunk_id = "chunk-1",
      row_count = 4L,
      input_ipc_payload = input_payload
    )
    expect_true(is.character(task_id))

    result <- provider$collect_many(task_id)[[1L]]
    expect_equal(result$status, "ok")
    expect_equal(result$udf_id, "plus_one")
    expect_equal(result$chunk_id, "chunk-1")
    expect_true(is.raw(result$output_ipc_payload))
    decoded <- Rducks:::rducks_arrow_ipc_decode_array(result$output_ipc_payload)
    expect_equal(as.data.frame(decoded$array)$result, 2:5)

    stats <- provider$stats()
    expect_equal(stats$provider, "mirai")
    expect_equal(stats$submitted, 1L)
    expect_equal(stats$completed, 1L)
    expect_equal(stats$pending, 0L)

    bad_task_id <- provider$submit(
      udf_id = "missing_udf",
      chunk_id = "chunk-bad",
      row_count = 4L,
      input_ipc_payload = input_payload
    )
    bad_result <- provider$collect_many(bad_task_id)[[1L]]
    expect_equal(bad_result$status, "error")
    expect_true(grepl("unknown Rducks mirai UDF id", bad_result$error_message))
    expect_true(provider$stats()$errors >= 1L)

    provider$register_udf(
      udf_id = "slow_identity",
      udf_name = "slow_identity",
      fun = function(x) {
        Sys.sleep(0.25)
        x
      },
      arg_types = list(INTEGER),
      return_type = INTEGER,
      mode = "vectorized",
      null_handling = "default",
      exception_handling = "rethrow",
      output_schema_spec = output_schema_spec
    )
    cancel_task_id <- provider$submit(
      udf_id = "slow_identity",
      chunk_id = "chunk-cancel",
      row_count = 4L,
      input_ipc_payload = input_payload
    )
    provider$cancel(cancel_task_id)
    cancel_stats <- provider$stats()
    expect_equal(cancel_stats$cancelled, 1L)
    expect_equal(cancel_stats$pending, 0L)

    timeout_task_id <- provider$submit(
      udf_id = "slow_identity",
      chunk_id = "chunk-timeout",
      row_count = 4L,
      input_ipc_payload = input_payload
    )
    expect_error(provider$collect_many(timeout_task_id, timeout = 0), "timed out")
    timeout_stats <- provider$stats()
    expect_equal(timeout_stats$pending, 0L)
    expect_true(timeout_stats$errors >= 2L)

    provider$stop()
    expect_false(provider$stats()$started)
  })
} else {
  expect_true(TRUE)
}
