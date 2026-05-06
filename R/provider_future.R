rducks_future_worker_eval_arrow_ipc_chunk <- function(input_payload,
                                                      output_schema_spec,
                                                      n,
                                                      fun,
                                                      arg_types,
                                                      return_type,
                                                      null_handling,
                                                      exception_handling,
                                                      mode) {
  n <- as.integer(n)
  mode <- rducks_match_mode(mode)
  decoded <- rducks_arrow_ipc_decode_array(input_payload)
  output_schema <- rducks_arrow_schema_from_spec(output_schema_spec)
  prepared <- rducks_scalar_prepare_inputs(arg_types, decoded$array, decoded$schema, n)
  results <- if (identical(mode, "scalar")) {
    rducks_scalar_eval_prepared_rows(
      fun,
      arg_types,
      return_type,
      prepared,
      null_handling,
      exception_handling
    )
  } else {
    rducks_vectorized_eval_prepared_chunk(
      fun,
      arg_types,
      return_type,
      prepared,
      null_handling,
      exception_handling
    )
  }
  result_array <- rducks_scalar_results_to_arrow(return_type, results, output_schema, n)
  rducks_arrow_ipc_encode(result_array)
}

rducks_future_worker_eval_vectorized_chunk <- function(input_payload,
                                                       output_schema_spec,
                                                       n,
                                                       fun,
                                                       arg_types,
                                                       return_type,
                                                       null_handling,
                                                       exception_handling) {
  rducks_future_worker_eval_arrow_ipc_chunk(
    input_payload = input_payload,
    output_schema_spec = output_schema_spec,
    n = n,
    fun = fun,
    arg_types = arg_types,
    return_type = return_type,
    null_handling = null_handling,
    exception_handling = exception_handling,
    mode = "vectorized"
  )
}

rducks_future_precompute_worker_globals <- function(fun, globals) {
  if (!identical(globals, "auto")) {
    return(list(globals = globals, packages = character()))
  }
  env <- list2env(list(fun = fun), parent = environment(fun) %||% parent.frame())
  gp <- future::getGlobalsAndPackages(quote(fun()), envir = env, globals = TRUE)
  values <- as.list(gp$globals)
  values$fun <- NULL
  list(
    globals = values,
    packages = as.character(gp$packages %||% character())
  )
}

rducks_future_required_globals <- function(env, globals) {
  required <- c(
    "input_payload",
    "output_schema_spec",
    "n",
    "fun",
    "arg_types",
    "return_type",
    "null_handling",
    "exception_handling",
    "mode"
  )
  if (isTRUE(globals)) {
    return(globals)
  }
  required_values <- mget(required, envir = env, inherits = FALSE)
  if (identical(globals, FALSE)) {
    return(required_values)
  }
  if (identical(globals, "auto")) {
    return(required_values)
  }
  if (is.character(globals)) {
    return(unique(c(required, globals)))
  }
  if (is.list(globals)) {
    if (length(globals) && (is.null(names(globals)) || any(!nzchar(names(globals))))) {
      stop("future_globals supplied as a list must be named", call. = FALSE)
    }
    required_values[setdiff(names(globals), names(required_values))] <- globals[setdiff(names(globals), names(required_values))]
    return(required_values)
  }
  TRUE
}

rducks_future_values <- function(futs, timeout, stdout) {
  batch <- is.list(futs) && !inherits(futs, "Future")
  relay_conditions <- !batch
  wait_for_values <- function() future::value(futs, stdout = stdout, signal = relay_conditions)
  values <- if (is.null(timeout)) {
    tryCatch(
      wait_for_values(),
      error = function(e) {
        lapply(as.list(futs), function(fut) try(future::cancel(fut), silent = TRUE))
        stop("Rducks Future worker failed: ", conditionMessage(e), call. = FALSE)
      }
    )
  } else {
    old <- options(future.wait.timeout = as.numeric(timeout))
    on.exit(options(old), add = TRUE)
    tryCatch(
      wait_for_values(),
      error = function(e) {
        lapply(as.list(futs), function(fut) try(future::cancel(fut), silent = TRUE))
        stop("Rducks Future worker failed while waiting up to ", timeout, " seconds: ", conditionMessage(e), call. = FALSE)
      }
    )
  }
  if (batch) {
    for (value in values) {
      if (inherits(value, "error")) {
        stop("Rducks Future worker failed: ", conditionMessage(value), call. = FALSE)
      }
    }
  }
  values
}

rducks_future_value <- function(fut, timeout, stdout) {
  rducks_future_values(fut, timeout, stdout)
}

rducks_future_start_vectorized_chunk <- function(engine, input_payload, output_schema_spec, n) {
  opts <- engine$plan$future_options %||% rducks_future_options()
  fun <- engine$fun
  arg_types <- engine$arg_types
  return_type <- engine$return_type
  null_handling <- engine$null_handling
  exception_handling <- engine$exception_handling
  mode <- engine$mode %||% "vectorized"
  globals <- rducks_future_required_globals(environment(), engine$future_globals %||% opts$globals)
  packages <- unique(c(opts$packages, engine$future_packages %||% character()))
  future::future(
    {
      worker_eval <- utils::getFromNamespace("rducks_future_worker_eval_arrow_ipc_chunk", "Rducks")
      worker_eval(
        input_payload = input_payload,
        output_schema_spec = output_schema_spec,
        n = n,
        fun = fun,
        arg_types = arg_types,
        return_type = return_type,
        null_handling = null_handling,
        exception_handling = exception_handling,
        mode = mode
      )
    },
    globals = globals,
    packages = packages,
    seed = opts$seed,
    stdout = opts$stdout,
    conditions = opts$conditions,
    label = paste0("rducks-arrow-ipc-", mode)
  )
}

rducks_future_collect_vectorized_chunk <- function(engine, fut) {
  opts <- engine$plan$future_options %||% rducks_future_options()
  rducks_future_value(fut, opts$timeout, stdout = opts$stdout)
}

rducks_future_collect_vectorized_chunks <- function(engine, futs) {
  opts <- engine$plan$future_options %||% rducks_future_options()
  rducks_future_values(futs, opts$timeout, stdout = opts$stdout)
}

rducks_future_submit_vectorized_chunk <- function(engine, input_payload, output_schema_spec, n) {
  fut <- rducks_future_start_vectorized_chunk(engine, input_payload, output_schema_spec, n)
  rducks_future_collect_vectorized_chunk(engine, fut)
}

rducks_arrow_ipc_future_submit_arrow_chunk <- function(engine, input_array, input_schema, output_schema, n,
                                                       output_schema_spec = NULL) {
  n <- as.integer(n)
  if (!nanoarrow::nanoarrow_pointer_is_valid(input_array)) {
    stop("input nanoarrow array pointer is not valid", call. = FALSE)
  }
  if (!nanoarrow::nanoarrow_pointer_is_valid(output_schema)) {
    stop("output nanoarrow schema pointer is not valid", call. = FALSE)
  }
  storage_input <- rducks_arrow_ipc_storage_input(engine$arg_types, input_array, input_schema)
  input_payload <- rducks_arrow_ipc_encode(storage_input$array)
  output_schema_spec <- output_schema_spec %||% rducks_arrow_schema_to_spec(output_schema)
  rducks_future_start_vectorized_chunk(engine, input_payload, output_schema_spec, n)
}

rducks_arrow_ipc_future_collect_arrow_chunk <- function(engine, fut, output_schema, n) {
  n <- as.integer(n)
  if (!nanoarrow::nanoarrow_pointer_is_valid(output_schema)) {
    stop("output nanoarrow schema pointer is not valid", call. = FALSE)
  }
  result_payload <- rducks_future_collect_vectorized_chunk(engine, fut)
  decoded_result <- rducks_arrow_ipc_decode_array(result_payload)
  decoded_result$array
}

rducks_arrow_ipc_future_collect_many_arrow_chunks <- function(engine, futs, output_schemas, ns) {
  if (!is.list(futs)) {
    stop("futs must be a list of Future objects", call. = FALSE)
  }
  if (!is.list(output_schemas) || length(output_schemas) != length(futs)) {
    stop("output_schemas must be a list with one schema per Future", call. = FALSE)
  }
  if (length(ns) != length(futs)) {
    stop("ns must have one row count per Future", call. = FALSE)
  }
  for (schema in output_schemas) {
    if (!nanoarrow::nanoarrow_pointer_is_valid(schema)) {
      stop("output nanoarrow schema pointer is not valid", call. = FALSE)
    }
  }
  result_payloads <- rducks_future_collect_vectorized_chunks(engine, futs)
  lapply(result_payloads, function(payload) rducks_arrow_ipc_decode_array(payload)$array)
}

rducks_arrow_ipc_future_evaluate_arrow_chunk <- function(engine, input_array, input_schema, output_schema, n,
                                                        output_schema_spec = NULL) {
  tryCatch({
    fut <- rducks_arrow_ipc_future_submit_arrow_chunk(
      engine, input_array, input_schema, output_schema, n,
      output_schema_spec = output_schema_spec
    )
    rducks_arrow_ipc_future_collect_arrow_chunk(engine, fut, output_schema, n)
  }, error = function(e) {
    msg <- paste0("Rducks Future Arrow IPC R function or marshal error: ", conditionMessage(e))
    .rducks_state$last_arrow_error <- msg
    rducks_arrow_error(msg)
  })
}
