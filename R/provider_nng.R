rducks_nng_provider_trace <- function(phase) {
  message("[rducks-nng-provider] ", phase)
}

rducks_nng_counter_next <- function(value) {
  value <- suppressWarnings(as.numeric(value %||% 0))
  if (length(value) != 1L || is.na(value) || !is.finite(value) || value < 0) value <- 0
  value + 1
}

rducks_nng_counter_label <- function(value) {
  format(value, scientific = FALSE, trim = TRUE)
}

rducks_nng_defaults <- list(
  control_timeout = 5,
  startup_timeout = 5,
  register_timeout = 5,
  shutdown_timeout = 2,
  stop_request_timeout = 1,
  minimum_timeout = 0.001,
  control_retries = 200L,
  retry_sleep = 0.01,
  per_attempt_timeout = 0.25,
  worker_send_timeout = 5
)

rducks_nng_supported_transports <- function() {
  c("abstract", "ipc", "unix", "tcp", "ws")
}

rducks_nng_runtime_transports <- function() {
  sysname <- Sys.info()[["sysname"]]
  if (identical(sysname, "Windows")) {
    return(c("ipc", "tcp"))
  }
  transports <- c("ipc", "tcp", "ws")
  if (identical(sysname, "Linux")) {
    transports <- c("abstract", transports, "unix")
  } else {
    transports <- c(transports, "unix")
  }
  transports
}

rducks_nng_default_transport <- function() {
  if (identical(Sys.info()[["sysname"]], "Linux")) "abstract" else "ipc"
}

rducks_nng_normalize_transport <- function(transport = NULL) {
  if (is.null(transport)) transport <- rducks_nng_default_transport()
  supported <- rducks_nng_supported_transports()
  if (!is.character(transport) || length(transport) != 1L || is.na(transport) || !(transport %in% supported)) {
    stop(
      "ipc_transport must be one of: ", paste(supported, collapse = ", "),
      call. = FALSE
    )
  }
  transport
}

rducks_nng_random_token <- function() {
  gsub("[^[:alnum:]]", "", nanonext::random(8L))
}

rducks_nng_elapsed <- function() {
  unname(proc.time()[["elapsed"]])
}

rducks_nng_error_label <- function(value) {
  code <- suppressWarnings(as.integer(value))
  msg <- tryCatch(nanonext::nng_error(code), error = function(e) "")
  if (!length(msg) || is.na(msg) || !nzchar(msg)) {
    paste0("NNG error ", code)
  } else {
    paste0(msg, " (", code, ")")
  }
}

rducks_nng_response_summary <- function(buf, limit = 16L) {
  if (!is.raw(buf)) {
    return(paste0("non-raw response of class ", paste(class(buf), collapse = "/")))
  }
  n <- length(buf)
  prefix <- paste(sprintf("%02x", as.integer(buf[seq_len(min(n, limit))])), collapse = " ")
  paste0("length=", n, if (n) paste0(", prefix=", prefix) else "")
}

rducks_nng_response_frame_ready <- function(buf, min_bytes = rducks_nng_wire_response_header_size) {
  is.raw(buf) && length(buf) >= min_bytes
}

rducks_nng_decode_response_checked <- function(resp, endpoint = "", phase = "control") {
  decoded <- tryCatch(
    rducks_nng_wire_decode_response(resp),
    error = function(e) {
      stop(
        "failed to decode Rducks NNG ", phase, " response",
        if (nzchar(endpoint %||% "")) paste0(" from ", endpoint) else "",
        ": ", conditionMessage(e), "; ", rducks_nng_response_summary(resp),
        call. = FALSE
      )
    }
  )
  decoded
}

rducks_nng_random_port <- function(n) {
  bytes <- as.integer(nanonext::random(2L * n, convert = FALSE))
  values <- bytes[seq_len(n)] * 256L + bytes[n + seq_len(n)]
  20000L + (values %% 45536L)
}

rducks_nng_socket_paths <- function(token, indexes) {
  names <- paste0(token, "-", indexes, ".sock")
  dirs <- unique(c(tempdir(), "/tmp"))
  for (dir in dirs) {
    if (!dir.exists(dir) || file.access(dir, 2L) != 0L) next
    paths <- file.path(dir, names)
    if (max(nchar(paths, type = "bytes"), 0L) <= 100L) {
      unlink(paths, force = TRUE)
      return(paths)
    }
  }
  paths <- file.path(tempdir(), names)
  unlink(paths, force = TRUE)
  paths
}

rducks_nng_endpoint_bundle <- function(workers, transport = NULL) {
  transport <- rducks_nng_normalize_transport(transport)
  token <- paste("rdn", Sys.getpid(), substr(rducks_nng_random_token(), 1L, 8L), sep = "-")
  indexes <- seq_len(workers)
  cleanup_paths <- character()
  short_socket_paths <- function() rducks_nng_socket_paths(token, indexes)
  endpoints <- switch(
    transport,
    abstract = paste0("abstract://", token, "-", indexes),
    ipc = {
      if (identical(Sys.info()[["sysname"]], "Windows")) {
        paste0("ipc://", token, "-", indexes)
      } else {
        cleanup_paths <- short_socket_paths()
        paste0("ipc://", cleanup_paths)
      }
    },
    unix = {
      cleanup_paths <- short_socket_paths()
      paste0("unix://", cleanup_paths)
    },
    tcp = paste0("tcp://127.0.0.1:", rducks_nng_random_port(workers)),
    ws = paste0("ws://127.0.0.1:", rducks_nng_random_port(workers))
  )
  list(endpoints = endpoints, cleanup_paths = cleanup_paths, transport = transport)
}

rducks_nng_worker_loop <- function(endpoint) {
  suppressPackageStartupMessages(library(Rducks))
  registry <- new.env(parent = emptyenv())
  sock <- nanonext::socket("rep", listen = endpoint)
  ctx <- nanonext::context(sock)
  on.exit({
    try(close(ctx), silent = TRUE)
    try(close(sock), silent = TRUE)
  }, add = TRUE)
  send_timeout_ms <- as.integer(max(1L, ceiling(rducks_nng_defaults$worker_send_timeout * 1000)))
  repeat {
    stop_requested <- FALSE
    req_raw <- nanonext::recv(ctx, mode = "raw", block = TRUE)
    if (nanonext::is_error_value(req_raw)) {
      rducks_nng_provider_trace(paste0("worker:recv:error:", rducks_nng_error_label(req_raw)))
      next
    }
    response <- tryCatch({
      req <- rducks_nng_wire_decode_request(req_raw)
      stop_requested <- identical(req$type, rducks_nng_wire_type_stop)
      if (stop_requested) {
        rducks_nng_wire_encode_response("ok", raw())
      } else if (identical(req$type, rducks_nng_wire_type_ping)) {
        rducks_nng_wire_encode_response("ok", raw())
      } else if (identical(req$type, rducks_nng_wire_type_register)) {
        rec <- unserialize(req$payload)
        for (pkg in rec$packages %||% character()) {
          suppressPackageStartupMessages(library(pkg, character.only = TRUE))
        }
        if (length(rec$globals %||% list())) {
          fun_env <- new.env(parent = environment(rec$fun) %||% .GlobalEnv)
          list2env(rec$globals, envir = fun_env)
          environment(rec$fun) <- fun_env
        }
        assign(req$udf_id, rec, envir = registry)
        rducks_nng_wire_encode_response("ok", raw())
      } else if (identical(req$type, rducks_nng_wire_type_execute)) {
        if (!exists(req$udf_id, envir = registry, inherits = FALSE)) {
          stop("unknown Rducks NNG UDF id: ", req$udf_id, call. = FALSE)
        }
        rec <- get(req$udf_id, envir = registry, inherits = FALSE)
        output <- rducks_ipc_worker_eval_arrow_ipc_chunk(
          input_payload = req$payload,
          output_schema_spec = rec$output_schema_spec,
          n = req$row_count,
          fun = rec$fun,
          arg_types = rec$arg_types,
          return_type = rec$return_type,
          null_handling = rec$null_handling,
          exception_handling = rec$exception_handling,
          mode = rec$mode
        )
        rducks_nng_wire_encode_response("ok", output)
      } else {
        stop("unknown Rducks NNG request type: ", req$type, call. = FALSE)
      }
    }, error = function(e) {
      rducks_nng_wire_encode_response("error", raw(), conditionMessage(e))
    })
    send_status <- nanonext::send(ctx, response, mode = "raw", block = send_timeout_ms)
    if (nanonext::is_error_value(send_status) || !identical(as.integer(send_status), 0L)) {
      rducks_nng_provider_trace(paste0("worker:send:error:", rducks_nng_error_label(send_status)))
    }
    if (stop_requested) break
  }
  TRUE
}

rducks_nng_control_get <- function(endpoint) {
  sock <- nanonext::socket("req", dial = endpoint)
  ctx <- nanonext::context(sock)
  list(sock = sock, ctx = ctx)
}

rducks_nng_control_close <- function(con) {
  if (is.null(con)) return(invisible(NULL))
  try(close(con$ctx), silent = TRUE)
  try(close(con$sock), silent = TRUE)
  invisible(NULL)
}



rducks_nng_transact <- function(endpoint, request,
                                 timeout = rducks_nng_defaults$control_timeout,
                                 retries = rducks_nng_defaults$control_retries,
                                 retry_sleep = rducks_nng_defaults$retry_sleep,
                                 per_attempt_timeout = rducks_nng_defaults$per_attempt_timeout,
                                 min_response_bytes = rducks_nng_wire_response_header_size) {
  timeout <- if (is.null(timeout)) rducks_nng_defaults$control_timeout else as.numeric(timeout)
  if (length(timeout) != 1L || is.na(timeout) || !is.finite(timeout) || timeout <= 0) {
    timeout <- rducks_nng_defaults$control_timeout
  }
  retries <- suppressWarnings(as.integer(retries))
  if (length(retries) != 1L || is.na(retries) || !is.finite(retries) || retries < 1L) {
    retries <- 1L
  }
  per_attempt_timeout <- if (is.null(per_attempt_timeout)) timeout else as.numeric(per_attempt_timeout)
  if (length(per_attempt_timeout) != 1L || is.na(per_attempt_timeout) ||
      !is.finite(per_attempt_timeout) || per_attempt_timeout <= 0) {
    per_attempt_timeout <- timeout
  }

  deadline <- rducks_nng_elapsed() + timeout
  last_error <- NULL

  for (i in seq_len(retries)) {
    remaining <- deadline - rducks_nng_elapsed()
    if (remaining <= 0) break

    attempt_seconds <- if (retries == 1L) remaining else min(remaining, per_attempt_timeout)
    attempt_timeout_ms <- as.integer(max(1L, ceiling(attempt_seconds * 1000)))
    con <- NULL

    out <- tryCatch({
      con <- rducks_nng_control_get(endpoint)
      aio <- nanonext::request(
        con$ctx,
        request,
        send_mode = "raw",
        recv_mode = "raw",
        timeout = attempt_timeout_ms
      )
      aio <- nanonext::call_aio(aio)
      response <- aio$data
      if (nanonext::is_error_value(response)) {
        stop(rducks_nng_error_label(response), call. = FALSE)
      }
      if (!is.raw(response)) {
        stop(
          "NNG response was not raw: ",
          paste(class(response), collapse = "/"),
          call. = FALSE
        )
      }
      if (!rducks_nng_response_frame_ready(response, min_response_bytes)) {
        stop("NNG response frame was too short: ", rducks_nng_response_summary(response), call. = FALSE)
      }
      response
    }, error = function(e) {
      rducks_nng_provider_trace(paste0("transact:error:", conditionMessage(e)))
      last_error <<- conditionMessage(e)
      NULL
    }, finally = {
      rducks_nng_control_close(con)
    })

    if (!is.null(out)) return(out)
    remaining <- deadline - rducks_nng_elapsed()
    if (remaining <= 0) break
    Sys.sleep(min(retry_sleep, max(0, remaining)))
  }

  stop(
    "Rducks NNG request failed for endpoint ", endpoint,
    ": ", last_error %||% "unknown error",
    call. = FALSE
  )
}

rducks_nng_provider_store <- function() {
  store <- .rducks_state$nng_providers
  if (is.null(store)) {
    store <- new.env(parent = emptyenv())
    .rducks_state$nng_providers <- store
  }
  store
}

rducks_nng_provider_key <- function(runtime_token, workers, max_pending, endpoints, transport) {
  endpoint_key <- if (is.null(endpoints)) paste0("<mirai-daemons:", transport, ">") else paste(endpoints, collapse = "\n")
  paste(runtime_token %||% paste("process", Sys.getpid(), sep = "-"), workers, max_pending %||% Inf,
        endpoint_key, sep = "\r")
}

rducks_nng_provider_for_runtime <- function(runtime_token, workers, max_pending, endpoints, transport = NULL) {
  runtime_token <- runtime_token %||% paste("process", Sys.getpid(), sep = "-")
  transport <- rducks_nng_normalize_transport(transport)
  key <- rducks_nng_provider_key(runtime_token, workers, max_pending, endpoints, transport)
  store <- rducks_nng_provider_store()
  if (exists(key, envir = store, inherits = FALSE)) {
    return(get(key, envir = store, inherits = FALSE)$provider)
  }
  provider <- rducks_nng_provider(workers = workers, max_pending = max_pending, endpoints = endpoints, transport = transport)
  assign(key, list(runtime_token = runtime_token, workers = workers, max_pending = max_pending,
                   endpoints = endpoints, transport = transport, provider = provider), envir = store)
  provider
}

rducks_nng_stop_runtime_providers <- function(runtime_token = NULL, quiet = FALSE) {
  store <- .rducks_state$nng_providers
  if (is.null(store)) return(invisible(list()))
  statuses <- list()
  for (key in ls(store, all.names = TRUE)) {
    record <- get(key, envir = store, inherits = FALSE)
    if (is.null(runtime_token) || identical(record$runtime_token, runtime_token)) {
      statuses[[key]] <- tryCatch(record$provider$stop(quiet = quiet), error = function(e) e)
      rm(list = key, envir = store)
    }
  }
  invisible(statuses)
}

rducks_nng_stop_all_providers <- function(quiet = FALSE) {
  rducks_nng_stop_runtime_providers(NULL, quiet = quiet)
}

rducks_nng_provider <- function(workers = 1L, compute = NULL, max_pending = 64L,
                                endpoints = NULL, transport = NULL) {
  workers <- rducks_validate_thread_count(workers, "workers")
  if (is.null(max_pending)) max_pending <- Inf
  if (!is.numeric(max_pending) || length(max_pending) != 1L || is.na(max_pending) || max_pending <= 0) {
    stop("max_pending must be NULL or a positive numeric scalar", call. = FALSE)
  }
  transport <- rducks_nng_normalize_transport(transport)
  external_endpoints <- !is.null(endpoints)
  if (external_endpoints && (!is.character(endpoints) || !length(endpoints) || anyNA(endpoints) || any(!nzchar(endpoints)))) {
    stop("ipc_endpoints must be NULL or a non-empty character vector of NNG endpoint URLs", call. = FALSE)
  }
  if (external_endpoints && length(endpoints) != workers) {
    stop("length(ipc_endpoints) must equal ipc_workers", call. = FALSE)
  }
  if (is.null(compute)) {
    counter <- rducks_nng_counter_next(.rducks_state$nng_provider_counter)
    .rducks_state$nng_provider_counter <- counter
    compute <- paste("rducks-nng", Sys.getpid(), rducks_nng_counter_label(counter), sep = "-")
  }
  state <- new.env(parent = emptyenv())
  state$started <- FALSE
  state$compute <- compute
  state$workers <- workers
  state$max_pending <- max_pending
  state$external_endpoints <- external_endpoints
  state$transport <- transport
  state$endpoints <- endpoints %||% character()
  state$cleanup_paths <- character()
  state$tasks <- list()
  state$submitted <- 0
  state$completed <- 0
  state$errors <- 0

  provider <- list()
  provider$start <- function(plan = NULL) {
    if (isTRUE(state$started)) return(invisible(provider))
    rducks_nng_provider_trace(paste0(state$transport, ":start:begin"))
    tryCatch({
      if (!isTRUE(state$external_endpoints)) {
        mirai::daemons(state$workers, dispatcher = FALSE, .compute = state$compute)
        setup <- mirai::everywhere({ library(Rducks); TRUE }, .compute = state$compute)
        setup_value <- mirai::collect_mirai(setup)
        if (inherits(setup_value, "errorValue")) stop(as.character(setup_value), call. = FALSE)
        bundle <- rducks_nng_endpoint_bundle(state$workers, state$transport)
        if (length(bundle$endpoints) != state$workers) {
          stop(
            "Rducks NNG endpoint bundle returned a worker count mismatch",
            call. = FALSE
          )
        }
        tasks <- vector("list", length(bundle$endpoints))
        worker_loop <- rducks_nng_worker_loop
        for (i in seq_along(bundle$endpoints)) {
          endpoint <- bundle$endpoints[[i]]
          tasks[[i]] <- mirai::mirai({
            worker_loop(endpoint)
          }, endpoint = endpoint, worker_loop = worker_loop, .compute = state$compute)
        }
        state$endpoints <- bundle$endpoints
        state$cleanup_paths <- bundle$cleanup_paths
        state$tasks <- tasks
      }
      ping <- rducks_nng_wire_encode_request(rducks_nng_wire_type_ping)
      for (endpoint in state$endpoints) {
        rducks_nng_provider_trace(paste0(state$transport, ":start:ping:start"))
        resp <- rducks_nng_transact(endpoint, ping, timeout = rducks_nng_defaults$startup_timeout)
        rducks_nng_provider_trace(paste0(state$transport, ":start:ping:response:bytes=", length(resp)))
        decoded <- rducks_nng_decode_response_checked(resp, endpoint, "startup ping")
        if (!identical(decoded$status, "ok")) stop(decoded$error, call. = FALSE)
      }
      state$started <- TRUE
      rducks_nng_provider_trace(paste0(state$transport, ":start:done"))
      invisible(provider)
    }, error = function(e) {
      if (!isTRUE(state$external_endpoints)) {
        try(mirai::daemons(0L, .compute = state$compute), silent = TRUE)
        unlink(state$cleanup_paths %||% character(), force = TRUE)
        state$cleanup_paths <- character()
        state$tasks <- list()
        state$endpoints <- character()
      }
      state$started <- FALSE
      stop(e)
    })
  }
  provider$stop <- function(timeout = rducks_nng_defaults$shutdown_timeout, quiet = FALSE) {
    shutdown_status <- list(
      stop_requests_sent = 0L,
      stop_request_errors = character(),
      tasks_total = length(state$tasks),
      tasks_resolved = 0L,
      tasks_unresolved = 0L,
      forced_daemon_shutdown = FALSE
    )
    if (isTRUE(state$started) && !isTRUE(state$external_endpoints)) {
      tasks <- state$tasks
      endpoints <- state$endpoints
      for (endpoint in endpoints) {
        req <- rducks_nng_wire_encode_request(rducks_nng_wire_type_stop)
        sent <- tryCatch({
          stop_timeout <- max(
            rducks_nng_defaults$minimum_timeout,
            min(rducks_nng_defaults$stop_request_timeout, as.numeric(timeout))
          )
          rducks_nng_transact(endpoint, req, timeout = stop_timeout, retries = 5L)
          TRUE
        }, error = function(e) {
          shutdown_status$stop_request_errors <<- c(shutdown_status$stop_request_errors, conditionMessage(e))
          FALSE
        })
        if (isTRUE(sent)) shutdown_status$stop_requests_sent <- shutdown_status$stop_requests_sent + 1L
      }
      if (length(tasks)) {
        unresolved <- function(task) {
          tryCatch(mirai::unresolved(task), error = function(e) TRUE)
        }
        deadline <- unname(proc.time()[["elapsed"]]) + max(0, as.numeric(timeout))
        while (any(vapply(tasks, unresolved, logical(1))) &&
               unname(proc.time()[["elapsed"]]) < deadline) {
          Sys.sleep(0.01)
        }
        resolved <- !vapply(tasks, unresolved, logical(1))
        shutdown_status$tasks_resolved <- sum(resolved)
        shutdown_status$tasks_unresolved <- sum(!resolved)
        for (task in tasks[resolved]) {
          try(mirai::collect_mirai(task), silent = TRUE)
        }
      }
      shutdown_status$forced_daemon_shutdown <- shutdown_status$tasks_unresolved > 0L || length(shutdown_status$stop_request_errors) > 0L
      try(mirai::daemons(0L, .compute = state$compute), silent = TRUE)
      unlink(state$cleanup_paths %||% character(), force = TRUE)
      state$cleanup_paths <- character()
      state$tasks <- list()
      state$endpoints <- character()
    }
    state$last_shutdown_status <- shutdown_status
    state$started <- FALSE
    if (!quiet && isTRUE(shutdown_status$forced_daemon_shutdown)) {
      warning(
        "Rducks NNG provider shutdown was forced: ", shutdown_status$tasks_unresolved,
        " worker task(s) unresolved; ", length(shutdown_status$stop_request_errors),
        " stop request error(s)",
        call. = FALSE
      )
    }
    invisible(shutdown_status)
  }
  provider$register_udf <- function(udf_id, udf_name, fun, arg_types, return_type, mode,
                                    null_handling, exception_handling, output_schema_spec,
                                    globals = NULL, packages = character(),
                                    timeout = rducks_nng_defaults$register_timeout) {
    rducks_nng_provider_trace(paste0(state$transport, ":register:begin"))
    if (!isTRUE(state$started)) stop("NNG provider is not started", call. = FALSE)
    mode <- rducks_match_mode(mode)
    packages <- unique(c("Rducks", packages %||% character()))
    rec <- list(
      udf_name = udf_name,
      fun = fun,
      arg_types = arg_types,
      return_type = return_type,
      mode = mode,
      null_handling = null_handling,
      exception_handling = exception_handling,
      output_schema_spec = output_schema_spec,
      globals = globals %||% list(),
      packages = packages
    )
    payload <- serialize(rec, NULL, xdr = FALSE)
    rducks_nng_provider_trace(paste0(state$transport, ":register:serialized"))
    for (endpoint in state$endpoints) {
      rducks_nng_provider_trace(paste0(state$transport, ":register:request:start"))
      resp <- rducks_nng_transact(
        endpoint,
        rducks_nng_wire_encode_request(rducks_nng_wire_type_register, udf_id, payload = payload),
        timeout = timeout
      )
      rducks_nng_provider_trace(paste0(state$transport, ":register:request:response:bytes=", length(resp)))
      decoded <- rducks_nng_decode_response_checked(resp, endpoint, "register")
      rducks_nng_provider_trace(paste0(state$transport, ":register:request:status:", decoded$status))
      if (!identical(decoded$status, "ok")) {
        rducks_nng_provider_trace(paste0(state$transport, ":register:request:error:", decoded$error))
        stop(decoded$error, call. = FALSE)
      }
    }
    rducks_nng_provider_trace(paste0(state$transport, ":register:done"))
    invisible(udf_id)
  }
  provider$endpoints <- function() state$endpoints
  provider$stats <- function() {
    data.frame(
      provider = "nng",
      compute = state$compute,
      workers = state$workers,
      max_pending = state$max_pending,
      started = isTRUE(state$started),
      transport = state$transport,
      endpoints = length(state$endpoints),
      stringsAsFactors = FALSE
    )
  }
  provider
}

rducks_next_nng_udf_id <- function() {
  counter <- rducks_nng_counter_next(.rducks_state$nng_udf_counter)
  .rducks_state$nng_udf_counter <- counter
  paste("rducks-nng-udf", Sys.getpid(), rducks_nng_counter_label(counter), sep = "-")
}

rducks_make_arrow_ipc_nng_wrapper <- function(fun, spec, null_handling, exception_handling,
                                              mode = c("scalar", "vectorized"),
                                              plan = rducks_execution_plan(),
                                              runtime_token = NULL) {
  mode <- rducks_match_mode(mode)
  engine <- if (identical(mode, "scalar")) {
    rducks_make_scalar_engine(fun, spec, null_handling, exception_handling, plan = plan)
  } else {
    rducks_make_vectorized_engine(fun, spec, null_handling, exception_handling, plan = plan)
  }
  engine$mode <- mode
  opts <- engine$plan$ipc_options %||% rducks_ipc_options()
  worker_state <- rducks_ipc_worker_globals(engine$fun, opts$globals)
  provider <- NULL
  provider_registered <- FALSE
  udf_id <- rducks_next_nng_udf_id()
  runtime_token <- runtime_token %||% paste("process", Sys.getpid(), sep = "-")

  ensure_provider_started <- function() {
    if (is.null(provider)) {
      provider <<- rducks_nng_provider_for_runtime(
        runtime_token = runtime_token,
        workers = engine$plan$ipc_workers %||% 1L,
        max_pending = engine$plan$ipc_max_pending %||% 64L,
        endpoints = opts$endpoints,
        transport = opts$transport
      )
      provider$start(engine$plan)
    }
    invisible(provider)
  }

  configure <- function(output_schema) {
    output_schema_spec <- rducks_arrow_schema_to_spec(output_schema)
    ensure_provider_started()
    if (!isTRUE(provider_registered)) {
      provider$register_udf(
        udf_id = udf_id,
        udf_name = spec$name,
        fun = engine$fun,
        arg_types = engine$arg_types,
        return_type = engine$return_type,
        mode = mode,
        null_handling = engine$null_handling,
        exception_handling = engine$exception_handling,
        output_schema_spec = output_schema_spec,
        globals = worker_state$globals,
        packages = unique(c(opts$packages, worker_state$packages)),
        timeout = opts$timeout %||% rducks_nng_defaults$register_timeout
      )
      provider_registered <<- TRUE
    }
    list(
      provider = "nng",
      endpoints = provider$endpoints(),
      udf_id = udf_id,
      timeout_ms = as.integer(ceiling(as.numeric(opts$timeout) * 1000)),
      max_pending = engine$plan$ipc_max_pending %||% Inf,
      external_endpoints = !is.null(opts$endpoints)
    )
  }

  list(provider = "nng", prepare = ensure_provider_started, configure = configure)
}

rducks_make_arrow_ipc_nng_scalar_wrapper <- function(fun, spec, null_handling, exception_handling,
                                                     plan = rducks_execution_plan(),
                                                     runtime_token = NULL) {
  rducks_make_arrow_ipc_nng_wrapper(fun, spec, null_handling, exception_handling,
                                    mode = "scalar", plan = plan, runtime_token = runtime_token)
}

rducks_make_arrow_ipc_nng_vectorized_wrapper <- function(fun, spec, null_handling, exception_handling,
                                                         plan = rducks_execution_plan(),
                                                         runtime_token = NULL) {
  rducks_make_arrow_ipc_nng_wrapper(fun, spec, null_handling, exception_handling,
                                    mode = "vectorized", plan = plan, runtime_token = runtime_token)
}
