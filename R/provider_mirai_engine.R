rducks_mirai_next_udf_id <- function() {
  counter <- .rducks_state$mirai_udf_counter %||% 0L
  counter <- counter + 1L
  .rducks_state$mirai_udf_counter <- counter
  paste("rducks-mirai-udf", Sys.getpid(), counter, sep = "-")
}

rducks_arrow_ipc_mirai_submit_arrow_chunk <- function(engine, provider, udf_id,
                                                      input_array, input_schema, output_schema, n,
                                                      output_schema_spec = NULL) {
  n <- as.integer(n)
  if (!rducks_nanoarrow_pointer_is_valid(input_array)) {
    stop("input nanoarrow array pointer is not valid", call. = FALSE)
  }
  if (!rducks_nanoarrow_pointer_is_valid(output_schema)) {
    stop("output nanoarrow schema pointer is not valid", call. = FALSE)
  }
  storage_input <- rducks_arrow_ipc_storage_input(engine$arg_types, input_array, input_schema)
  input_payload <- rducks_arrow_ipc_encode(storage_input$array)
  provider$submit(
    udf_id = udf_id,
    chunk_id = paste0("chunk-", n),
    row_count = n,
    input_ipc_payload = input_payload
  )
}

rducks_arrow_ipc_mirai_collect_payloads <- function(engine, provider, task_ids) {
  opts <- engine$plan$future_options %||% rducks_future_options()
  results <- provider$collect_many(task_ids, timeout = opts$timeout)
  lapply(results, function(result) {
    if (!identical(result$status, "ok")) {
      stop("Rducks mirai worker failed: ", result$error_message %||% "unknown error", call. = FALSE)
    }
    result$output_ipc_payload
  })
}

rducks_arrow_ipc_mirai_collect_arrow_chunk <- function(engine, provider, task_id, output_schema, n) {
  n <- as.integer(n)
  if (!rducks_nanoarrow_pointer_is_valid(output_schema)) {
    stop("output nanoarrow schema pointer is not valid", call. = FALSE)
  }
  payload <- rducks_arrow_ipc_mirai_collect_payloads(engine, provider, task_id)[[1L]]
  rducks_arrow_ipc_decode_array(payload)$array
}

rducks_arrow_ipc_mirai_collect_many_arrow_chunks <- function(engine, provider, task_ids, output_schemas, ns) {
  if (!is.list(output_schemas) || length(output_schemas) != length(task_ids)) {
    stop("output_schemas must be a list with one schema per task", call. = FALSE)
  }
  if (length(ns) != length(task_ids)) {
    stop("ns must have one row count per task", call. = FALSE)
  }
  for (schema in output_schemas) {
    if (!rducks_nanoarrow_pointer_is_valid(schema)) {
      stop("output nanoarrow schema pointer is not valid", call. = FALSE)
    }
  }
  payloads <- rducks_arrow_ipc_mirai_collect_payloads(engine, provider, task_ids)
  lapply(payloads, function(payload) rducks_arrow_ipc_decode_array(payload)$array)
}

rducks_arrow_ipc_mirai_collect_any_arrow_chunks <- function(engine, provider, task_ids, output_schemas, ns,
                                                           max_results = Inf) {
  task_ids <- unlist(task_ids, use.names = FALSE)
  if (!is.list(output_schemas) || length(output_schemas) != length(task_ids)) {
    stop("output_schemas must be a list with one schema per task", call. = FALSE)
  }
  if (length(ns) != length(task_ids)) {
    stop("ns must have one row count per task", call. = FALSE)
  }
  for (schema in output_schemas) {
    if (!rducks_nanoarrow_pointer_is_valid(schema)) {
      stop("output nanoarrow schema pointer is not valid", call. = FALSE)
    }
  }
  results <- provider$collect_any(
    max_results = max_results,
    timeout = 0.001,
    task_ids = task_ids
  )
  if (!length(results)) {
    return(list(indices = integer(), arrays = list()))
  }
  ids <- vapply(results, function(result) result$task_id %||% NA_character_, character(1))
  indices <- match(ids, task_ids)
  if (anyNA(indices)) {
    stop("Rducks mirai collect-any returned an unknown task id", call. = FALSE)
  }
  arrays <- vector("list", length(results))
  for (i in seq_along(results)) {
    result <- results[[i]]
    if (!identical(result$status, "ok")) {
      stop("Rducks mirai worker failed: ", result$error_message %||% "unknown error", call. = FALSE)
    }
    arrays[[i]] <- rducks_arrow_ipc_decode_array(result$output_ipc_payload)$array
  }
  list(indices = as.integer(indices), arrays = arrays)
}

rducks_make_arrow_ipc_mirai_wrapper <- function(fun, spec, null_handling, exception_handling,
                                                mode = c("scalar", "vectorized"),
                                                plan = rducks_execution_plan()) {
  rducks_mirai_require()
  mode <- rducks_match_mode(mode)
  engine <- if (identical(mode, "scalar")) {
    rducks_make_scalar_engine(fun, spec, null_handling, exception_handling, plan = plan)
  } else {
    rducks_make_vectorized_engine(fun, spec, null_handling, exception_handling, plan = plan)
  }
  engine$mode <- mode
  opts <- engine$plan$future_options %||% rducks_future_options()
  worker_state <- rducks_mirai_worker_globals(engine$fun, opts$globals)
  provider <- NULL
  provider_registered <- FALSE
  udf_id <- rducks_mirai_next_udf_id()
  output_schema_spec_cache <- NULL
  finalizer_env <- new.env(parent = emptyenv())
  finalizer_env$provider <- NULL
  reg.finalizer(finalizer_env, function(env) {
    if (!is.null(env$provider)) try(env$provider$stop(), silent = TRUE)
  }, onexit = TRUE)

  ensure_provider <- function(output_schema) {
    if (is.null(output_schema_spec_cache)) {
      output_schema_spec_cache <<- rducks_arrow_schema_to_spec(output_schema)
    }
    if (is.null(provider)) {
      provider <<- rducks_mirai_provider(
        workers = engine$plan$ipc_workers %||% 1L,
        max_pending = engine$plan$ipc_max_pending %||% 64L
      )
      provider$start(engine$plan)
      finalizer_env$provider <- provider
    }
    if (!isTRUE(provider_registered)) {
      tryCatch({
        provider$register_udf(
          udf_id = udf_id,
          udf_name = spec$name,
          fun = engine$fun,
          arg_types = engine$arg_types,
          return_type = engine$return_type,
          mode = mode,
          null_handling = engine$null_handling,
          exception_handling = engine$exception_handling,
          output_schema_spec = output_schema_spec_cache,
          globals = worker_state$globals,
          packages = unique(c(opts$packages, worker_state$packages))
        )
        provider_registered <<- TRUE
      }, error = function(e) {
        try(provider$stop(), silent = TRUE)
        provider <<- NULL
        finalizer_env$provider <- NULL
        stop(e)
      })
    }
    provider
  }

  list(
    execute = function(input_array, input_schema, output_schema, n) {
      tryCatch({
        active_provider <- ensure_provider(output_schema)
        task_id <- rducks_arrow_ipc_mirai_submit_arrow_chunk(
          engine, active_provider, udf_id, input_array, input_schema, output_schema, n,
          output_schema_spec = output_schema_spec_cache
        )
        rducks_arrow_ipc_mirai_collect_arrow_chunk(engine, active_provider, task_id, output_schema, n)
      }, error = function(e) {
        msg <- paste0("Rducks mirai Arrow IPC R function or marshal error: ", conditionMessage(e))
        .rducks_state$last_arrow_error <- msg
        rducks_arrow_error(msg)
      })
    },
    submit = function(input_array, input_schema, output_schema, n) {
      tryCatch({
        active_provider <- ensure_provider(output_schema)
        rducks_arrow_ipc_mirai_submit_arrow_chunk(
          engine, active_provider, udf_id, input_array, input_schema, output_schema, n,
          output_schema_spec = output_schema_spec_cache
        )
      }, error = function(e) {
        msg <- paste0("Rducks mirai Arrow IPC submit error: ", conditionMessage(e))
        .rducks_state$last_arrow_error <- msg
        rducks_arrow_error(msg)
      })
    },
    collect = function(task_id, output_schema, n) {
      tryCatch(
        rducks_arrow_ipc_mirai_collect_arrow_chunk(engine, provider, task_id, output_schema, n),
        error = function(e) {
          msg <- paste0("Rducks mirai Arrow IPC collect error: ", conditionMessage(e))
          .rducks_state$last_arrow_error <- msg
          rducks_arrow_error(msg)
        }
      )
    },
    collect_many = function(task_ids, output_schemas, ns) {
      tryCatch(
        rducks_arrow_ipc_mirai_collect_many_arrow_chunks(
          engine, provider, unlist(task_ids, use.names = FALSE), output_schemas, ns
        ),
        error = function(e) {
          msg <- paste0("Rducks mirai Arrow IPC collect-many error: ", conditionMessage(e))
          .rducks_state$last_arrow_error <- msg
          rducks_arrow_error(msg)
        }
      )
    },
    collect_any = function(task_ids, output_schemas, ns, max_results = Inf) {
      tryCatch(
        rducks_arrow_ipc_mirai_collect_any_arrow_chunks(
          engine, provider, task_ids, output_schemas, ns, max_results = max_results
        ),
        error = function(e) {
          msg <- paste0("Rducks mirai Arrow IPC collect-any error: ", conditionMessage(e))
          .rducks_state$last_arrow_error <- msg
          rducks_arrow_error(msg)
        }
      )
    },
    cancel = function(task_ids) {
      tryCatch({
        if (!is.null(provider)) provider$cancel(unlist(task_ids, use.names = FALSE))
        TRUE
      }, error = function(e) {
        msg <- paste0("Rducks mirai Arrow IPC cancel error: ", conditionMessage(e))
        .rducks_state$last_arrow_error <- msg
        rducks_arrow_error(msg)
      })
    },
    .finalizer = finalizer_env
  )
}

rducks_make_arrow_ipc_mirai_scalar_wrapper <- function(fun, spec, null_handling, exception_handling,
                                                       plan = rducks_execution_plan()) {
  rducks_make_arrow_ipc_mirai_wrapper(fun, spec, null_handling, exception_handling, mode = "scalar", plan = plan)
}

rducks_make_arrow_ipc_mirai_vectorized_wrapper <- function(fun, spec, null_handling, exception_handling,
                                                           plan = rducks_execution_plan()) {
  rducks_make_arrow_ipc_mirai_wrapper(fun, spec, null_handling, exception_handling, mode = "vectorized", plan = plan)
}
