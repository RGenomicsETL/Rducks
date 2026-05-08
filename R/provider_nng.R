rducks_nng_counter_next <- function(value) {
  value <- suppressWarnings(as.numeric(value %||% 0))
  if (length(value) != 1L || is.na(value) || !is.finite(value) || value < 0) value <- 0
  value + 1
}

rducks_nng_counter_label <- function(value) {
  format(value, scientific = FALSE, trim = TRUE)
}

rducks_nng_supported_transports <- function() {
  c("abstract", "ipc", "unix", "tcp", "ws")
}

rducks_nng_runtime_transports <- function() {
  sysname <- Sys.info()[["sysname"]]
  transports <- c("ipc", "tcp", "ws")
  if (identical(sysname, "Linux")) {
    transports <- c("abstract", transports, "unix")
  } else if (!identical(sysname, "Windows")) {
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
    ws = paste0("ws://127.0.0.1:", rducks_nng_random_port(workers), "/", token, "/", indexes)
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
  repeat {
    req_raw <- nanonext::recv(ctx, mode = "raw", block = TRUE)
    response <- tryCatch({
      req <- rducks_nng_wire_decode_request(req_raw)
      if (identical(req$type, rducks_nng_wire_type_stop)) {
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
    nanonext::send(ctx, response, mode = "raw", block = TRUE)
    decoded <- tryCatch(rducks_nng_wire_decode_request(req_raw), error = function(e) NULL)
    if (!is.null(decoded) && identical(decoded$type, rducks_nng_wire_type_stop)) break
  }
  TRUE
}

rducks_nng_transact <- function(endpoint, request, timeout = 5, retries = 200L,
                                 retry_sleep = 0.01, per_attempt_timeout = 0.25) {
  timeout <- if (is.null(timeout)) 5 else as.numeric(timeout)
  if (!is.finite(timeout) || timeout <= 0) timeout <- 5
  deadline <- unname(proc.time()[["elapsed"]]) + timeout
  last_error <- NULL
  for (i in seq_len(retries)) {
    remaining <- deadline - unname(proc.time()[["elapsed"]])
    if (remaining <= 0) break
    timeout_ms <- as.integer(max(1L, ceiling(min(remaining, per_attempt_timeout) * 1000)))
    sock <- NULL
    ctx <- NULL
    out <- tryCatch({
      sock <- nanonext::socket("req", dial = endpoint)
      ctx <- nanonext::context(sock)
      aio <- nanonext::request(ctx, request, send_mode = "raw", recv_mode = "raw", timeout = timeout_ms)
      nanonext::call_aio(aio)
      response <- aio$data
      if (nanonext::is_error_value(response)) stop(as.character(response), call. = FALSE)
      response
    }, error = function(e) {
      last_error <<- conditionMessage(e)
      NULL
    }, finally = {
      if (!is.null(ctx)) try(close(ctx), silent = TRUE)
      if (!is.null(sock)) try(close(sock), silent = TRUE)
    })
    if (!is.null(out)) return(out)
    if (deadline - unname(proc.time()[["elapsed"]]) <= 0) break
    Sys.sleep(min(retry_sleep, max(0, deadline - unname(proc.time()[["elapsed"]]))))
  }
  stop("Rducks NNG request failed for endpoint ", endpoint, ": ", last_error %||% "unknown error", call. = FALSE)
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

rducks_nng_stop_runtime_providers <- function(runtime_token = NULL) {
  store <- .rducks_state$nng_providers
  if (is.null(store)) return(invisible(NULL))
  for (key in ls(store, all.names = TRUE)) {
    record <- get(key, envir = store, inherits = FALSE)
    if (is.null(runtime_token) || identical(record$runtime_token, runtime_token)) {
      try(record$provider$stop(), silent = TRUE)
      rm(list = key, envir = store)
    }
  }
  invisible(NULL)
}

rducks_nng_stop_all_providers <- function() {
  rducks_nng_stop_runtime_providers(NULL)
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
    tryCatch({
      if (!isTRUE(state$external_endpoints)) {
        mirai::daemons(state$workers, dispatcher = FALSE, .compute = state$compute)
        setup <- mirai::everywhere({ library(Rducks); TRUE }, .compute = state$compute)
        setup_value <- mirai::collect_mirai(setup)
        if (inherits(setup_value, "errorValue")) stop(as.character(setup_value), call. = FALSE)
        bundle <- rducks_nng_endpoint_bundle(state$workers, state$transport)
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
      state$started <- TRUE
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
  provider$stop <- function() {
    if (isTRUE(state$started) && !isTRUE(state$external_endpoints)) {
      tasks <- state$tasks
      for (endpoint in state$endpoints) {
        req <- rducks_nng_wire_encode_request(rducks_nng_wire_type_stop)
        try(rducks_nng_transact(endpoint, req, timeout = 1, retries = 5L), silent = TRUE)
      }
      if (length(tasks)) {
        deadline <- unname(proc.time()[["elapsed"]]) + 1
        while (any(vapply(tasks, mirai::unresolved, logical(1))) &&
               unname(proc.time()[["elapsed"]]) < deadline) {
          Sys.sleep(0.01)
        }
        for (task in tasks) {
          if (!isTRUE(mirai::unresolved(task))) try(mirai::collect_mirai(task), silent = TRUE)
        }
      }
      try(mirai::daemons(0L, .compute = state$compute), silent = TRUE)
      unlink(state$cleanup_paths %||% character(), force = TRUE)
      state$cleanup_paths <- character()
      state$tasks <- list()
      state$endpoints <- character()
    }
    state$started <- FALSE
    invisible(provider)
  }
  provider$register_udf <- function(udf_id, udf_name, fun, arg_types, return_type, mode,
                                    null_handling, exception_handling, output_schema_spec,
                                    globals = NULL, packages = character(), timeout = 5) {
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
    for (endpoint in state$endpoints) {
      resp <- rducks_nng_transact(
        endpoint,
        rducks_nng_wire_encode_request(rducks_nng_wire_type_register, udf_id, payload = payload),
        timeout = timeout
      )
      decoded <- rducks_nng_wire_decode_response(resp)
      if (!identical(decoded$status, "ok")) stop(decoded$error, call. = FALSE)
    }
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
        timeout = opts$timeout %||% 5
      )
      provider_registered <<- TRUE
    }
    list(
      provider = "nng",
      endpoints = provider$endpoints(),
      udf_id = udf_id,
      timeout_ms = if (is.null(opts$timeout)) 0L else as.integer(ceiling(as.numeric(opts$timeout) * 1000))
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
