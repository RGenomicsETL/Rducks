rducks_make_scalar_engine <- function(fun, spec, null_handling, exception_handling,
                                      plan = rducks_execution_plan()) {
  force(fun)
  force(spec)
  force(null_handling)
  force(exception_handling)
  force(plan)
  list(
    fun = fun,
    arg_types = spec$arg_types,
    return_type = spec$return_type,
    null_handling = null_handling,
    exception_handling = exception_handling,
    plan = plan,
    prepare_inputs = rducks_scalar_prepare_inputs,
    eval_rows = rducks_scalar_eval_prepared_rows,
    results_to_arrow = rducks_scalar_results_to_arrow,
    serialization = if (identical(plan$serialization, "arrow_ipc")) list(
      kind = "arrow_ipc",
      encode = rducks_arrow_ipc_encode,
      decode_stream = rducks_arrow_ipc_decode_stream
    ) else NULL
  )
}

rducks_make_vectorized_engine <- function(fun, spec, null_handling, exception_handling,
                                          plan = rducks_execution_plan()) {
  force(fun)
  force(spec)
  force(null_handling)
  force(exception_handling)
  force(plan)
  list(
    fun = fun,
    arg_types = spec$arg_types,
    return_type = spec$return_type,
    null_handling = null_handling,
    exception_handling = exception_handling,
    plan = plan,
    prepare_inputs = rducks_scalar_prepare_inputs,
    eval_rows = rducks_vectorized_eval_prepared_chunk,
    results_to_arrow = rducks_scalar_results_to_arrow,
    serialization = if (identical(plan$serialization, "arrow_ipc")) list(
      kind = "arrow_ipc",
      encode = rducks_arrow_ipc_encode,
      decode_stream = rducks_arrow_ipc_decode_stream
    ) else NULL
  )
}

rducks_scalar_evaluate_arrow_chunk <- function(engine, input_array, input_schema, output_schema, n,
                                               dynamic_arg_tokens = NULL) {
  tryCatch({
    n <- as.integer(n)
    if (!nanoarrow::nanoarrow_pointer_is_valid(output_schema)) {
      stop("output nanoarrow schema pointer is not valid", call. = FALSE)
    }
    arg_types <- rducks_resolve_dynamic_arg_types(engine$arg_types, dynamic_arg_tokens)
    prepared <- engine$prepare_inputs(arg_types, input_array, input_schema, n)
    results <- engine$eval_rows(
      engine$fun,
      arg_types,
      engine$return_type,
      prepared,
      engine$null_handling,
      engine$exception_handling
    )
    engine$results_to_arrow(engine$return_type, results, output_schema, n)
  }, error = function(e) {
    msg <- paste0("Rducks nanoarrow R function or marshal error: ", conditionMessage(e))
    .rducks_state$last_arrow_error <- msg
    rducks_arrow_error(msg)
  })
}

rducks_rc_prepare_inputs <- rducks_scalar_prepare_inputs

rducks_make_rc_bundle <- function(fun, spec, null_handling, exception_handling, plan, engine, eval_rows) {
  list(
    fun = fun,
    arg_types = spec$arg_types,
    return_type = spec$return_type,
    prepare_inputs = rducks_scalar_prepare_inputs,
    check_return = rducks_check_scalar_udf_return,
    result_array = rducks_arrow_result_array,
    eval_rows = eval_rows,
    results_to_arrow = rducks_scalar_results_to_arrow,
    engine = engine,
    plan = plan,
    null_handling = null_handling,
    exception_handling = exception_handling
  )
}

rducks_make_rc_scalar_bundle <- function(fun, spec,
                                         null_handling = "default",
                                         exception_handling = "rethrow",
                                         plan = rducks_execution_plan()) {
  engine <- rducks_make_scalar_engine(
    fun, spec,
    null_handling = null_handling,
    exception_handling = exception_handling,
    plan = plan
  )
  rducks_make_rc_bundle(
    fun, spec,
    null_handling = null_handling,
    exception_handling = exception_handling,
    plan = plan,
    engine = engine,
    eval_rows = rducks_scalar_eval_prepared_rows
  )
}

rducks_make_rc_vectorized_bundle <- function(fun, spec,
                                             null_handling = "default",
                                             exception_handling = "rethrow",
                                             plan = rducks_execution_plan()) {
  engine <- rducks_make_vectorized_engine(
    fun, spec,
    null_handling = null_handling,
    exception_handling = exception_handling,
    plan = plan
  )
  rducks_make_rc_bundle(
    fun, spec,
    null_handling = null_handling,
    exception_handling = exception_handling,
    plan = plan,
    engine = engine,
    eval_rows = rducks_vectorized_eval_prepared_chunk
  )
}

rducks_make_arrow_scalar_wrapper <- function(fun, spec, null_handling, exception_handling,
                                             plan = rducks_execution_plan()) {
  engine <- rducks_make_scalar_engine(fun, spec, null_handling, exception_handling, plan = plan)
  function(input_array, input_schema, output_schema, n, dynamic_arg_tokens = NULL) {
    rducks_scalar_evaluate_arrow_chunk(engine, input_array, input_schema, output_schema, n, dynamic_arg_tokens)
  }
}

rducks_make_arrow_vectorized_wrapper <- function(fun, spec, null_handling, exception_handling,
                                                 plan = rducks_execution_plan()) {
  engine <- rducks_make_vectorized_engine(fun, spec, null_handling, exception_handling, plan = plan)
  function(input_array, input_schema, output_schema, n, dynamic_arg_tokens = NULL) {
    rducks_scalar_evaluate_arrow_chunk(engine, input_array, input_schema, output_schema, n, dynamic_arg_tokens)
  }
}
