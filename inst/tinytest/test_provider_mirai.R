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

    expect_equal(provider$collect_many(character()), list())

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

  local({
    provider <- Rducks:::rducks_mirai_provider(workers = 1L, max_pending = 1L)
    provider$start()
    on.exit(provider$stop(), add = TRUE)

    input_array <- nanoarrow::as_nanoarrow_array(data.frame(arg1 = 1:4))
    input_payload <- Rducks:::rducks_arrow_ipc_encode(input_array)
    output_schema_spec <- Rducks:::rducks_arrow_schema_to_spec(
      nanoarrow::infer_nanoarrow_schema(data.frame(result = integer()))
    )
    provider$register_udf(
      udf_id = "slow_limit",
      udf_name = "slow_limit",
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
    task_id <- provider$submit("slow_limit", "chunk-one", 4L, input_payload)
    expect_error(
      provider$submit("slow_limit", "chunk-two", 4L, input_payload),
      "pending task limit"
    )
    provider$cancel(task_id)
    expect_equal(provider$stats()$max_pending, 1)
  })

  local({
    provider <- Rducks:::rducks_mirai_provider(workers = 2L, max_pending = 2L)
    provider$start()
    on.exit(provider$stop(), add = TRUE)

    input_array <- nanoarrow::as_nanoarrow_array(data.frame(arg1 = 1:4))
    input_payload <- Rducks:::rducks_arrow_ipc_encode(input_array)
    output_schema_spec <- Rducks:::rducks_arrow_schema_to_spec(
      nanoarrow::infer_nanoarrow_schema(data.frame(result = integer()))
    )
    provider$register_udf(
      udf_id = "slow_any",
      udf_name = "slow_any",
      fun = function(x) {
        Sys.sleep(5)
        x
      },
      arg_types = list(INTEGER),
      return_type = INTEGER,
      mode = "vectorized",
      null_handling = "default",
      exception_handling = "rethrow",
      output_schema_spec = output_schema_spec
    )
    provider$register_udf(
      udf_id = "fast_any",
      udf_name = "fast_any",
      fun = function(x) x + 1L,
      arg_types = list(INTEGER),
      return_type = INTEGER,
      mode = "vectorized",
      null_handling = "default",
      exception_handling = "rethrow",
      output_schema_spec = output_schema_spec
    )
    slow_id <- provider$submit("slow_any", "slow", 4L, input_payload)
    fast_id <- provider$submit("fast_any", "fast", 4L, input_payload)
    none <- provider$collect_any(max_results = 1L, timeout = 0.01, task_ids = slow_id)
    expect_equal(none, list())
    ready <- provider$collect_any(max_results = 1L, timeout = 2, task_ids = c(slow_id, fast_id))
    expect_equal(length(ready), 1L)
    expect_equal(ready[[1L]]$chunk_id, "fast")
    provider$cancel(slow_id)
    expect_equal(provider$stats()$pending, 0L)
    expect_error(provider$collect_many(slow_id), "unknown Rducks mirai task id")
    expect_error(provider$collect_many(c(fast_id, fast_id)), "duplicates")
  })

  local({
    provider <- Rducks:::rducks_mirai_provider(workers = 2L, max_pending = 2L)
    provider$start()
    on.exit(provider$stop(), add = TRUE)

    input_array <- nanoarrow::as_nanoarrow_array(data.frame(arg1 = 1:4))
    input_payload <- Rducks:::rducks_arrow_ipc_encode(input_array)
    output_schema_spec <- Rducks:::rducks_arrow_schema_to_spec(
      nanoarrow::infer_nanoarrow_schema(data.frame(result = integer()))
    )
    provider$register_udf(
      udf_id = "slow_timeout_many",
      udf_name = "slow_timeout_many",
      fun = function(x) {
        Sys.sleep(5)
        x
      },
      arg_types = list(INTEGER),
      return_type = INTEGER,
      mode = "vectorized",
      null_handling = "default",
      exception_handling = "rethrow",
      output_schema_spec = output_schema_spec
    )
    provider$register_udf(
      udf_id = "fast_timeout_many",
      udf_name = "fast_timeout_many",
      fun = function(x) x + 1L,
      arg_types = list(INTEGER),
      return_type = INTEGER,
      mode = "vectorized",
      null_handling = "default",
      exception_handling = "rethrow",
      output_schema_spec = output_schema_spec
    )
    slow_id <- provider$submit("slow_timeout_many", "slow", 4L, input_payload)
    fast_id <- provider$submit("fast_timeout_many", "fast", 4L, input_payload)
    expect_error(provider$collect_many(c(slow_id, fast_id), timeout = 1), "timed out waiting for task")
    stats <- provider$stats()
    expect_equal(stats$pending, 0L)
    expect_true(stats$errors >= 1L)
  })
} else {
  expect_true(TRUE)
}
