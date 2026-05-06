library(Rducks)

local({
  env <- list2env(list(
    input_payload = raw(),
    output_schema_spec = list(),
    n = 0L,
    fun = function() NULL,
    arg_types = list(),
    return_type = INTEGER,
    null_handling = "default",
    exception_handling = "rethrow",
    mode = "vectorized"
  ), parent = emptyenv())

  required_false <- Rducks:::rducks_future_required_globals(env, FALSE)
  expect_true(all(c("input_payload", "output_schema_spec", "mode") %in% names(required_false)))

  required_auto <- Rducks:::rducks_future_required_globals(env, "auto")
  expect_equal(names(required_auto), names(required_false))

  expect_true(isTRUE(Rducks:::rducks_future_required_globals(env, TRUE)))
  expect_equal(
    Rducks:::rducks_future_required_globals(env, "extra_global"),
    unique(c(names(required_false), "extra_global"))
  )
  merged <- Rducks:::rducks_future_required_globals(env, list(extra = 1L))
  expect_equal(merged$extra, 1L)
  expect_error(
    Rducks:::rducks_future_required_globals(env, list(1L)),
    "must be named"
  )

  helper_offset <- 2L
  globals <- Rducks:::rducks_future_precompute_worker_globals(function() helper_offset, "auto")
  expect_true("helper_offset" %in% names(globals$globals))
  expect_equal(globals$globals$helper_offset, 2L)
  explicit <- Rducks:::rducks_future_precompute_worker_globals(function() helper_offset, FALSE)
  expect_false(is.null(explicit$globals))
})

local({
  old_plan <- future::plan()
  on.exit(future::plan(old_plan), add = TRUE)
  future::plan(future::sequential)

  fut1 <- future::future(stop("future boom"))
  expect_error(
    Rducks:::rducks_future_value(fut1, NULL, stdout = FALSE),
    "Rducks Future worker failed"
  )

  fut2 <- future::future(stop("future timeout boom"))
  expect_error(
    Rducks:::rducks_future_value(fut2, 1, stdout = FALSE),
    "waiting up to 1 seconds"
  )
})

local({
  input_array <- nanoarrow::as_nanoarrow_array(data.frame(arg1 = 1:3))
  input_payload <- Rducks:::rducks_arrow_ipc_encode(input_array)
  output_schema_spec <- Rducks:::rducks_arrow_schema_to_spec(
    nanoarrow::infer_nanoarrow_schema(data.frame(result = integer()))
  )
  output_payload <- Rducks:::rducks_future_worker_eval_arrow_ipc_chunk(
    input_payload = input_payload,
    output_schema_spec = output_schema_spec,
    n = 3L,
    fun = function(x) x + 1L,
    arg_types = list(INTEGER),
    return_type = INTEGER,
    null_handling = "default",
    exception_handling = "rethrow",
    mode = "vectorized"
  )
  expect_true(is.raw(input_payload))
  expect_true(is.raw(output_payload))
  decoded_output <- Rducks:::rducks_arrow_ipc_decode_array(output_payload)
  expect_equal(as.data.frame(decoded_output$array)$result, 2:4)
})

local({
  engine <- list(plan = rducks_execution_plan("arrow_ipc", "multiprocess_parallel"))
  expect_error(
    Rducks:::rducks_arrow_ipc_future_collect_arrow_chunk(engine, future::future(raw()), list(), 0L),
    "schema pointer"
  )
  expect_error(
    Rducks:::rducks_arrow_ipc_future_collect_many_arrow_chunks(engine, future::future(raw()), list(), integer()),
    "futs must be a list"
  )
  expect_error(
    Rducks:::rducks_arrow_ipc_future_collect_many_arrow_chunks(engine, list(future::future(raw())), list(), 0L),
    "one schema per Future"
  )
  expect_error(
    Rducks:::rducks_arrow_ipc_future_collect_many_arrow_chunks(engine, list(future::future(raw())), list(list()), integer()),
    "one row count"
  )
  expect_error(
    Rducks:::rducks_arrow_ipc_future_collect_many_arrow_chunks(engine, list(future::future(raw())), list(list()), 0L),
    "schema pointer"
  )

  out <- Rducks:::rducks_arrow_ipc_future_evaluate_arrow_chunk(engine, list(), list(), list(), 0L)
  expect_inherits(out, "rducks_arrow_error")
})
