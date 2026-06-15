rducks_nng_provider_trace_enabled <- function() {
  opt <- getOption("rducks.nng.trace", FALSE)
  env <- tolower(Sys.getenv("RDUCKS_NNG_TRACE", ""))
  isTRUE(opt) || env %in% c("1", "true", "yes", "on")
}

rducks_nng_provider_trace <- function(phase) {
  if (rducks_nng_provider_trace_enabled()) {
    message("[rducks-nng-provider] ", phase)
  }
  invisible(NULL)
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
  worker_send_timeout = 5,
  worker_registry_max_entries = 4096L,
  startup_attempts = 3L,
  startup_retry_sleep = 0.05
)

rducks_nng_check_seconds <- function(x, what, default = NULL, minimum = 0) {
  if (is.null(x)) x <- default
  x <- suppressWarnings(as.numeric(x))
  if (length(x) != 1L || is.na(x) || !is.finite(x) || x <= minimum) {
    stop(
      what,
      " must be a finite numeric scalar greater than ",
      format(minimum, scientific = FALSE, trim = TRUE),
      call. = FALSE
    )
  }
  x
}

rducks_nng_timeout_ms <- function(seconds, what = "timeout") {
  seconds <- rducks_nng_check_seconds(seconds, what)
  as.integer(max(1L, ceiling(seconds * 1000)))
}

rducks_nng_startup_attempts <- function(transport) {
  attempts <- getOption("rducks.nng.startup_attempts", rducks_nng_defaults$startup_attempts)
  attempts <- suppressWarnings(as.integer(attempts))
  if (length(attempts) != 1L || is.na(attempts) || attempts < 1L) attempts <- 1L
  if (transport %in% c("tcp", "ws")) attempts else 1L
}

rducks_nng_validate_endpoints <- function(endpoints, workers = NULL, allow_null = TRUE,
                                          what = "ipc_endpoints") {
  if (is.null(endpoints)) {
    if (allow_null) return(NULL)
    stop(what, " must be a non-empty character vector of NNG endpoint URLs", call. = FALSE)
  }
  if (!is.character(endpoints) || !length(endpoints) || anyNA(endpoints) || any(!nzchar(endpoints))) {
    stop(what, " must be a non-empty character vector of NNG endpoint URLs", call. = FALSE)
  }
  if (!is.null(workers) && length(endpoints) != workers) {
    stop("length(", what, ") must equal ipc_workers", call. = FALSE)
  }
  endpoints
}

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

rducks_nng_normalize_transport <- function(transport = NULL, runtime = FALSE) {
  if (is.null(transport)) transport <- rducks_nng_default_transport()
  supported <- if (isTRUE(runtime)) rducks_nng_runtime_transports() else rducks_nng_supported_transports()
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

rducks_nng_collect_mirai <- function(task, timeout, what) {
  timeout <- rducks_nng_check_seconds(timeout, paste0(what, " timeout"),
                                      default = rducks_nng_defaults$startup_timeout)
  deadline <- rducks_nng_elapsed() + timeout
  repeat {
    unresolved <- tryCatch(mirai::unresolved(task), error = function(e) FALSE)
    if (!isTRUE(unresolved)) break
    remaining <- deadline - rducks_nng_elapsed()
    if (remaining <= 0) {
      stop(what, " timed out after ", format(timeout, scientific = FALSE, trim = TRUE),
           " seconds", call. = FALSE)
    }
    Sys.sleep(min(0.01, remaining))
  }
  value <- mirai::collect_mirai(task)
  if (mirai::is_mirai_error(value)) stop(as.character(value), call. = FALSE)
  value
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
  n <- as.integer(n)
  if (length(n) != 1L || is.na(n) || n < 1L) return(integer())
  ports <- integer()
  attempts <- 0L
  while (length(ports) < n && attempts < 100L) {
    attempts <- attempts + 1L
    batch <- max(n - length(ports), n)
    bytes <- as.integer(nanonext::random(2L * batch, convert = FALSE))
    values <- bytes[seq_len(batch)] * 256L + bytes[batch + seq_len(batch)]
    ports <- unique(c(ports, 20000L + (values %% 45536L)))
  }
  if (length(ports) < n) {
    stop("failed to generate unique local NNG ports", call. = FALSE)
  }
  ports[seq_len(n)]
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
  transport <- rducks_nng_normalize_transport(transport, runtime = TRUE)
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

rducks_nng_worker_registry_limit <- function() {
  value <- getOption("rducks.nng.worker_registry_max_entries", rducks_nng_defaults$worker_registry_max_entries)
  value <- suppressWarnings(as.integer(value))
  if (length(value) != 1L || is.na(value) || value < 1L) {
    value <- rducks_nng_defaults$worker_registry_max_entries
  }
  value
}

rducks_nng_worker_loop <- function(endpoint) {
  suppressPackageStartupMessages(library(Rducks))
  registry <- new.env(parent = emptyenv())
  registry_order <- character()
  registry_max <- rducks_nng_worker_registry_limit()
  sock <- NULL
  ctx <- NULL
  on.exit({
    try(if (!is.null(ctx)) close(ctx), silent = TRUE)
    try(if (!is.null(sock)) close(sock), silent = TRUE)
  }, add = TRUE)
  sock <- nanonext::socket("rep", listen = endpoint)
  ctx <- nanonext::context(sock)
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
        registry_order <- c(registry_order[registry_order != req$udf_id], req$udf_id)
        while (length(registry_order) > registry_max) {
          rm(list = registry_order[[1L]], envir = registry)
          registry_order <- registry_order[-1L]
        }
        rducks_nng_wire_encode_response("ok", raw())
      } else if (identical(req$type, rducks_nng_wire_type_execute)) {
        if (!exists(req$udf_id, envir = registry, inherits = FALSE)) {
          stop("unknown Rducks NNG UDF id: ", req$udf_id, call. = FALSE)
        }
        rec <- get(req$udf_id, envir = registry, inherits = FALSE)
        output <- rducks_ipc_worker_eval_quack_chunk(
          input_payload = req$payload,
          n = req$row_count,
          fun = rec$fun,
          arg_types = rec$arg_types,
          return_type = rec$return_type,
          null_handling = rec$null_handling,
          exception_handling = rec$exception_handling,
          mode = rec$mode,
          dynamic_arg_tokens = req$dynamic_arg_tokens
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
  timeout <- rducks_nng_check_seconds(timeout, "timeout", default = rducks_nng_defaults$control_timeout)
  retries <- suppressWarnings(as.integer(retries))
  if (length(retries) != 1L || is.na(retries) || !is.finite(retries) || retries < 1L) {
    retries <- 1L
  }
  per_attempt_timeout <- rducks_nng_check_seconds(per_attempt_timeout, "per_attempt_timeout", default = timeout)

  deadline <- rducks_nng_elapsed() + timeout
  last_error <- NULL

  for (i in seq_len(retries)) {
    remaining <- deadline - rducks_nng_elapsed()
    if (remaining <= 0) break

    attempt_seconds <- if (retries == 1L) remaining else min(remaining, per_attempt_timeout)
    attempt_timeout_ms <- rducks_nng_timeout_ms(attempt_seconds, "attempt timeout")
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
  rducks_get_or_init_store("nng_providers")
}

rducks_nng_plan_timeout <- function(plan, default) {
  opts <- plan$ipc_options %||% list()
  opts$timeout %||% default
}

rducks_nng_ping_endpoints <- function(endpoints, transport, timeout = rducks_nng_defaults$startup_timeout) {
  ping <- rducks_nng_wire_encode_request(rducks_nng_wire_type_ping)
  for (endpoint in endpoints) {
    rducks_nng_provider_trace(paste0(transport, ":start:ping:start"))
    resp <- rducks_nng_transact(endpoint, ping, timeout = timeout)
    rducks_nng_provider_trace(paste0(transport, ":start:ping:response:bytes=", length(resp)))
    decoded <- rducks_nng_decode_response_checked(resp, endpoint, "startup ping")
    if (!identical(decoded$status, "ok")) stop(decoded$error, call. = FALSE)
  }
  invisible(TRUE)
}

rducks_nng_shutdown_status <- function(tasks_total = 0L) {
  list(
    stop_requests_sent = 0L,
    stop_request_errors = character(),
    tasks_total = as.integer(tasks_total),
    tasks_resolved = 0L,
    tasks_unresolved = 0L,
    forced_daemon_shutdown = FALSE
  )
}

rducks_nng_backend_external <- function(endpoints, transport) {
  list(
    name = "external",
    capabilities = list(
      local_only = FALSE,
      supports_mori_global_sharing = FALSE,
      supports_chunk_shared_memory_handles = FALSE,
      supports_shared_memory_handles = FALSE,
      supports_cancellation = FALSE,
      supports_remote_endpoints = TRUE
    ),
    start = function(state, plan = NULL) {
      rducks_nng_ping_endpoints(
        state$endpoints,
        state$transport,
        timeout = rducks_nng_plan_timeout(plan, rducks_nng_defaults$startup_timeout)
      )
      list(endpoints = state$endpoints, cleanup_paths = character(), tasks = list())
    },
    stop = function(state, timeout, quiet = FALSE) {
      rducks_nng_shutdown_status(0L)
    },
    cleanup = function(state) invisible(NULL)
  )
}

rducks_nng_backend_mirai <- function(compute, workers, transport) {
  cleanup_record <- function(record) {
    # Ask mirai daemons to stop explicitly before reaping them. On Windows,
    # relying on reap-only shutdown can leave idle daemon R processes holding
    # inherited R CMD check handles open in some CI hosts.
    try(mirai::daemons(NULL, .compute = compute), silent = TRUE)
    unlink(record$cleanup_paths %||% character(), force = TRUE)
    invisible(NULL)
  }

  list(
    name = "mirai",
    capabilities = list(
      local_only = TRUE,
      supports_mori_global_sharing = TRUE,
      supports_chunk_shared_memory_handles = FALSE,
      supports_shared_memory_handles = FALSE,
      supports_cancellation = FALSE,
      supports_remote_endpoints = FALSE
    ),
    start = function(state, plan = NULL) {
      last_record <- NULL
      start_once <- function() {
        mirai::daemons(workers, dispatcher = FALSE, .compute = compute)
        setup_timeout <- rducks_nng_plan_timeout(plan, rducks_nng_defaults$startup_timeout)
        setup <- mirai::everywhere({ library(Rducks); TRUE }, .compute = compute)
        rducks_nng_collect_mirai(setup, setup_timeout, "Rducks NNG worker setup")
        bundle <- rducks_nng_endpoint_bundle(workers, transport)
        if (length(bundle$endpoints) != workers) {
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
          }, endpoint = endpoint, worker_loop = worker_loop, .compute = compute)
        }
        record <- list(endpoints = bundle$endpoints, cleanup_paths = bundle$cleanup_paths, tasks = tasks)
        last_record <<- record
        rducks_nng_ping_endpoints(
          record$endpoints,
          transport,
          timeout = rducks_nng_plan_timeout(plan, rducks_nng_defaults$startup_timeout)
        )
        record
      }

      attempts <- rducks_nng_startup_attempts(transport)
      last_error <- NULL
      for (attempt in seq_len(attempts)) {
        rducks_nng_provider_trace(paste0(transport, ":start:attempt:", attempt, "/", attempts))
        record <- tryCatch({
          last_record <- NULL
          out <- start_once()
          last_record <<- out
          out
        }, error = function(e) {
          last_error <<- conditionMessage(e)
          rducks_nng_provider_trace(paste0(transport, ":start:attempt:error:", last_error))
          cleanup_record(last_record %||% list(cleanup_paths = character()))
          NULL
        })
        if (!is.null(record)) return(record)
        if (attempt < attempts) Sys.sleep(rducks_nng_defaults$startup_retry_sleep)
      }
      stop(last_error %||% "Rducks NNG provider startup failed", call. = FALSE)
    },
    stop = function(state, timeout, quiet = FALSE) {
      shutdown_status <- rducks_nng_shutdown_status(length(state$tasks))
      tasks <- state$tasks
      endpoints <- state$endpoints
      for (endpoint in endpoints) {
        req <- rducks_nng_wire_encode_request(rducks_nng_wire_type_stop)
        sent <- tryCatch({
          stop_timeout <- max(
            rducks_nng_defaults$minimum_timeout,
            min(rducks_nng_defaults$stop_request_timeout, timeout)
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
        deadline <- rducks_nng_elapsed() + timeout
        while (any(vapply(tasks, unresolved, logical(1))) &&
               rducks_nng_elapsed() < deadline) {
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
      cleanup_record(list(cleanup_paths = state$cleanup_paths))
      state$cleanup_paths <- character()
      state$tasks <- list()
      state$endpoints <- character()
      shutdown_status
    },
    cleanup = function(state) {
      cleanup_record(list(cleanup_paths = state$cleanup_paths))
      state$cleanup_paths <- character()
      state$tasks <- list()
      state$endpoints <- character()
      invisible(NULL)
    }
  )
}

rducks_nng_validate_backend <- function(backend) {
  if (is.null(backend)) return(NULL)
  if (!is.list(backend) || !is.function(backend$start) || !is.function(backend$stop)) {
    stop("NNG lifecycle backend must be a list with start() and stop() functions", call. = FALSE)
  }
  if (is.null(backend$name)) backend$name <- "custom"
  if (is.null(backend$capabilities)) backend$capabilities <- list()
  if (is.null(backend$capabilities$supports_mori_global_sharing)) {
    backend$capabilities$supports_mori_global_sharing <- FALSE
  }
  if (is.null(backend$capabilities$supports_chunk_shared_memory_handles)) {
    backend$capabilities$supports_chunk_shared_memory_handles <- isTRUE(backend$capabilities$supports_shared_memory_handles)
  }
  if (is.null(backend$capabilities$supports_shared_memory_handles)) {
    backend$capabilities$supports_shared_memory_handles <- isTRUE(backend$capabilities$supports_chunk_shared_memory_handles)
  }
  if (is.null(backend$cleanup)) backend$cleanup <- function(state) invisible(NULL)
  backend
}

rducks_nng_provider_key <- function(runtime_token, workers, max_pending, endpoints, transport) {
  endpoint_key <- if (is.null(endpoints)) paste0("<managed-workers:", transport, ">") else paste(endpoints, collapse = "\n")
  paste(runtime_token %||% paste("process", Sys.getpid(), sep = "-"), workers, max_pending %||% Inf,
        endpoint_key, sep = "\r")
}

rducks_nng_provider_key_parts <- function(runtime_token, workers, max_pending, endpoints, transport = NULL) {
  runtime_token <- runtime_token %||% paste("process", Sys.getpid(), sep = "-")
  external_endpoints <- !is.null(endpoints)
  if (external_endpoints && !is.null(transport)) {
    stop("ipc_transport only applies when ipc_endpoints is NULL", call. = FALSE)
  }
  transport <- if (external_endpoints) "external" else rducks_nng_normalize_transport(transport, runtime = TRUE)
  list(
    runtime_token = runtime_token,
    workers = workers,
    max_pending = max_pending,
    endpoints = endpoints,
    transport = transport,
    key = rducks_nng_provider_key(runtime_token, workers, max_pending, endpoints, transport)
  )
}

rducks_nng_remove_provider_record <- function(parts, quiet = TRUE) {
  store <- .rducks_state$nng_providers
  if (is.null(store) || !exists(parts$key, envir = store, inherits = FALSE)) {
    return(invisible(NULL))
  }
  record <- get(parts$key, envir = store, inherits = FALSE)
  if (is.list(record$provider) && is.function(record$provider$stop)) {
    try(record$provider$stop(quiet = quiet), silent = TRUE)
  }
  rm(list = parts$key, envir = store)
  invisible(NULL)
}

rducks_nng_provider_for_runtime <- function(runtime_token, workers, max_pending, endpoints, transport = NULL) {
  parts <- rducks_nng_provider_key_parts(runtime_token, workers, max_pending, endpoints, transport)
  store <- rducks_nng_provider_store()
  if (exists(parts$key, envir = store, inherits = FALSE)) {
    return(get(parts$key, envir = store, inherits = FALSE)$provider)
  }
  provider <- rducks_nng_provider(
    workers = workers,
    max_pending = max_pending,
    endpoints = parts$endpoints,
    transport = if (identical(parts$transport, "external")) NULL else parts$transport
  )
  assign(parts$key, list(runtime_token = parts$runtime_token, workers = workers, max_pending = max_pending,
                         endpoints = endpoints, transport = parts$transport, provider = provider), envir = store)
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

rducks_ipc_workers_empty <- function() {
  out <- data.frame(
    runtime_token = character(),
    provider = character(),
    backend = character(),
    compute = character(),
    transport = character(),
    worker = integer(),
    workers = integer(),
    started = logical(),
    endpoint = character(),
    task_state = character(),
    ping = character(),
    stringsAsFactors = FALSE
  )
  class(out) <- c("rducks_ipc_workers", class(out))
  out
}

rducks_ipc_worker_task_state <- function(task, external = FALSE, started = FALSE) {
  if (isTRUE(external)) return(if (isTRUE(started)) "external" else "not_started")
  if (is.null(task)) return(if (isTRUE(started)) "unknown" else "not_started")
  unresolved <- tryCatch(mirai::unresolved(task), error = function(e) NA)
  if (is.na(unresolved)) return("unknown")
  if (isTRUE(unresolved)) "running" else "resolved"
}

rducks_ipc_worker_ping <- function(endpoint, timeout) {
  if (is.na(endpoint) || !nzchar(endpoint)) return(NA_character_)
  tryCatch({
    resp <- rducks_nng_transact(
      endpoint,
      rducks_nng_wire_encode_request(rducks_nng_wire_type_ping),
      timeout = timeout,
      retries = 1L
    )
    decoded <- rducks_nng_decode_response_checked(resp, endpoint, "worker ping")
    if (identical(decoded$status, "ok")) "ok" else paste0("error: ", decoded$error)
  }, error = function(e) paste0("error: ", conditionMessage(e)))
}

rducks_ipc_workers_from_store <- function(runtime_token = NULL, ping = FALSE, timeout = 1) {
  store <- .rducks_state$nng_providers
  if (is.null(store)) return(rducks_ipc_workers_empty())
  rows <- list()
  for (key in ls(store, all.names = TRUE)) {
    record <- get(key, envir = store, inherits = FALSE)
    if (!is.null(runtime_token) && !identical(record$runtime_token, runtime_token)) next
    provider <- record$provider
    if (!is.list(provider) || !is.function(provider$worker_stats)) next
    rows[[length(rows) + 1L]] <- provider$worker_stats(
      runtime_token = record$runtime_token,
      ping = ping,
      timeout = timeout
    )
  }
  if (!length(rows)) return(rducks_ipc_workers_empty())
  out <- do.call(rbind, rows)
  row.names(out) <- NULL
  class(out) <- c("rducks_ipc_workers", "data.frame")
  out
}

#' List Rducks-managed IPC workers
#'
#' Lists the local Rducks NNG providers currently known to this R process. These
#' are the managed workers used by `transport = "ipc"` scalar-UDF
#' execution plans when `ipc_endpoints` is not supplied. Caller-supplied external
#' endpoints are shown as external providers.
#'
#' @param con Optional DuckDB connection. When supplied, only providers attached
#'   to that connection's Rducks runtime token are listed. With `NULL`, all
#'   providers known to this R process are listed.
#' @param ping Logical scalar. If `TRUE`, send a lightweight NNG ping to every
#'   listed endpoint and report `ok` or the ping error.
#' @param timeout Positive timeout in seconds used for `ping = TRUE`.
#' @return A data frame with one row per configured worker endpoint.
#' @examples
#' \donttest{
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db)
#' rducks_ipc_workers(db)
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
#' @export
rducks_ipc_workers <- function(con = NULL, ping = FALSE, timeout = 1) {
  if (!is.logical(ping) || length(ping) != 1L || is.na(ping)) {
    stop("ping must be TRUE or FALSE", call. = FALSE)
  }
  timeout <- rducks_nng_check_seconds(timeout, "timeout", default = 1,
                                      minimum = rducks_nng_defaults$minimum_timeout)
  runtime_token <- NULL
  if (!is.null(con)) {
    rducks_assert_duckdb_connection(con)
    runtime_token <- rducks_runtime_token(con, required = FALSE)
    if (is.na(runtime_token)) return(rducks_ipc_workers_empty())
  }
  rducks_ipc_workers_from_store(runtime_token = runtime_token, ping = ping,
                                timeout = timeout)
}

rducks_shorten_worker_endpoint <- function(x, width = 60L) {
  x <- as.character(x)
  missing <- is.na(x) | !nzchar(x)
  too_wide <- !missing & nchar(x, type = "width") > width
  x[missing] <- ""
  x[too_wide] <- paste0(substr(x[too_wide], 1L, width - 3L), "...")
  x
}

#' @export
print.rducks_ipc_workers <- function(x, ..., endpoints = FALSE) {
  n <- nrow(x)
  if (!n) {
    cat("<rducks_ipc_workers> no workers\n")
    return(invisible(x))
  }
  out <- as.data.frame(x)
  out$runtime <- rducks_shorten_worker_endpoint(out$runtime_token, 20L)
  out$worker <- paste0(out$worker, "/", out$workers)
  out$endpoint <- if (isTRUE(endpoints)) {
    as.character(out$endpoint)
  } else {
    rducks_shorten_worker_endpoint(out$endpoint, 42L)
  }
  out <- out[, c("runtime", "backend", "transport", "worker", "started",
                 "task_state", "ping", "endpoint"), drop = FALSE]
  cat("<rducks_ipc_workers: ", n, " worker", if (n == 1L) "" else "s", ">\n", sep = "")
  print.data.frame(out, row.names = FALSE, ...)
  invisible(x)
}

rducks_nng_provider <- function(workers = 1L, compute = NULL, max_pending = 64L,
                                endpoints = NULL, transport = NULL,
                                backend = NULL) {
  workers <- rducks_validate_thread_count(workers, "workers")
  if (is.null(max_pending)) max_pending <- Inf
  if (!is.numeric(max_pending) || length(max_pending) != 1L || is.na(max_pending) || max_pending <= 0) {
    stop("max_pending must be NULL or a positive numeric scalar", call. = FALSE)
  }
  backend <- rducks_nng_validate_backend(backend)
  external_endpoints <- !is.null(endpoints)
  if (external_endpoints && !is.null(transport)) {
    stop("ipc_transport only applies when ipc_endpoints is NULL", call. = FALSE)
  }
  transport <- if (external_endpoints) "external" else rducks_nng_normalize_transport(transport, runtime = TRUE)
  endpoints <- rducks_nng_validate_endpoints(endpoints, workers = if (external_endpoints) workers else NULL)
  if (is.null(compute)) {
    counter <- rducks_nng_counter_next(.rducks_state$nng_provider_counter)
    .rducks_state$nng_provider_counter <- counter
    compute <- paste("rducks-nng", Sys.getpid(), rducks_nng_counter_label(counter), sep = "-")
  }
  if (is.null(backend)) {
    backend <- if (external_endpoints) {
      rducks_nng_backend_external(endpoints, transport)
    } else {
      rducks_nng_backend_mirai(compute, workers, transport)
    }
  }
  state <- new.env(parent = emptyenv())
  state$started <- FALSE
  state$compute <- compute
  state$workers <- workers
  state$max_pending <- max_pending
  state$external_endpoints <- external_endpoints
  state$transport <- transport
  state$backend <- backend
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
      started <- state$backend$start(state, plan)
      if (is.null(started)) started <- list()
      state$endpoints <- started$endpoints %||% state$endpoints
      state$cleanup_paths <- started$cleanup_paths %||% state$cleanup_paths
      state$tasks <- started$tasks %||% state$tasks
      state$started <- TRUE
      rducks_nng_provider_trace(paste0(state$transport, ":start:done"))
      invisible(provider)
    }, error = function(e) {
      state$backend$cleanup(state)
      state$started <- FALSE
      stop(conditionMessage(e), call. = FALSE)
    })
  }
  provider$stop <- function(timeout = rducks_nng_defaults$shutdown_timeout, quiet = FALSE) {
    timeout <- rducks_nng_check_seconds(timeout, "timeout", default = rducks_nng_defaults$shutdown_timeout)
    shutdown_status <- if (isTRUE(state$started)) {
      state$backend$stop(state, timeout = timeout, quiet = quiet)
    } else {
      rducks_nng_shutdown_status(length(state$tasks))
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
                                    null_handling, exception_handling,
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
  provider$capabilities <- function() state$backend$capabilities %||% list()
  provider$stats <- function() {
    data.frame(
      provider = "nng",
      backend = state$backend$name %||% "custom",
      compute = state$compute,
      workers = state$workers,
      max_pending = state$max_pending,
      started = isTRUE(state$started),
      transport = state$transport,
      endpoints = length(state$endpoints),
      stringsAsFactors = FALSE
    )
  }
  provider$worker_stats <- function(runtime_token = NA_character_, ping = FALSE,
                                    timeout = 1) {
    n <- max(state$workers, length(state$endpoints), length(state$tasks), 0L)
    if (!n) return(rducks_ipc_workers_empty())
    endpoint <- rep(NA_character_, n)
    endpoint[seq_along(state$endpoints)] <- state$endpoints
    task_state <- vapply(seq_len(n), function(i) {
      task <- if (i <= length(state$tasks)) state$tasks[[i]] else NULL
      rducks_ipc_worker_task_state(
        task,
        external = isTRUE(state$external_endpoints),
        started = isTRUE(state$started)
      )
    }, character(1L))
    ping_status <- rep(NA_character_, n)
    if (isTRUE(ping)) {
      ping_status <- vapply(endpoint, rducks_ipc_worker_ping,
                            character(1L), timeout = timeout)
    }
    data.frame(
      runtime_token = runtime_token,
      provider = "nng",
      backend = state$backend$name %||% "custom",
      compute = state$compute,
      transport = state$transport,
      worker = seq_len(n),
      workers = state$workers,
      started = isTRUE(state$started),
      endpoint = endpoint,
      task_state = task_state,
      ping = ping_status,
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

rducks_make_wire_ipc_nng_wrapper_impl <- function(fun, spec, null_handling, exception_handling,
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
  worker_state <- rducks_ipc_worker_globals(engine$fun, opts$globals, share = opts$globals_share %||% "none")
  provider <- NULL
  provider_registered <- FALSE
  udf_id <- rducks_next_nng_udf_id()
  runtime_token <- runtime_token %||% paste("process", Sys.getpid(), sep = "-")

  ensure_provider_started <- function() {
    if (is.null(provider)) {
      workers <- engine$plan$ipc_workers %||% 1L
      max_pending <- engine$plan$ipc_max_pending %||% 64L
      parts <- rducks_nng_provider_key_parts(runtime_token, workers, max_pending, opts$endpoints, opts$transport)
      provider <<- rducks_nng_provider_for_runtime(
        runtime_token = runtime_token,
        workers = workers,
        max_pending = max_pending,
        endpoints = opts$endpoints,
        transport = opts$transport
      )
      tryCatch(
        provider$start(engine$plan),
        error = function(e) {
          rducks_nng_remove_provider_record(parts, quiet = TRUE)
          provider <<- NULL
          stop(conditionMessage(e), call. = FALSE)
        }
      )
    }
    invisible(provider)
  }

  # output_schema is a vestigial placeholder kept for the native call shape
  # (rducks_ripc.c invokes configure() with a single NULL argument); quack
  # payloads are self-describing, so no output schema is needed.
  configure <- function(output_schema) {
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
      timeout_ms = as.integer(ceiling(as.numeric(opts$timeout %||% rducks_nng_defaults$register_timeout) * 1000)),
      max_pending = engine$plan$ipc_max_pending %||% Inf,
      external_endpoints = !is.null(opts$endpoints)
    )
  }

  list(provider = "nng", prepare = ensure_provider_started, configure = configure)
}

rducks_make_wire_ipc_nng_scalar_wrapper <- function(fun, spec, null_handling, exception_handling,
                                                     plan = rducks_execution_plan(),
                                                     runtime_token = NULL) {
  rducks_make_wire_ipc_nng_wrapper_impl(fun, spec, null_handling, exception_handling,
                                    mode = "scalar", plan = plan, runtime_token = runtime_token)
}

rducks_make_wire_ipc_nng_vectorized_wrapper <- function(fun, spec, null_handling, exception_handling,
                                                         plan = rducks_execution_plan(),
                                                         runtime_token = NULL) {
  rducks_make_wire_ipc_nng_wrapper_impl(fun, spec, null_handling, exception_handling,
                                    mode = "vectorized", plan = plan, runtime_token = runtime_token)
}
