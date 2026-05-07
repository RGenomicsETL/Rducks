rducks_mirai_require <- function() {
  if (!requireNamespace("mirai", quietly = TRUE)) {
    stop("mirai provider requires the mirai package", call. = FALSE)
  }
  invisible(TRUE)
}

rducks_mirai_collect_map <- function(x) {
  out <- mirai::collect_mirai(x)
  if (inherits(out, "errorValue")) {
    stop("Rducks mirai provider setup failed: ", as.character(out), call. = FALSE)
  }
  out
}

rducks_mirai_worker_globals <- function(fun, globals) {
  if (identical(globals, "auto") || isTRUE(globals)) {
    return(rducks_future_precompute_worker_globals(fun, "auto"))
  }
  if (identical(globals, FALSE) || is.null(globals)) {
    return(list(globals = list(), packages = character()))
  }
  if (is.character(globals)) {
    env <- environment(fun) %||% parent.frame()
    return(list(globals = mget(globals, envir = env, inherits = TRUE), packages = character()))
  }
  if (is.list(globals)) {
    if (length(globals) && (is.null(names(globals)) || any(!nzchar(names(globals))))) {
      stop("future_globals supplied as a list must be named", call. = FALSE)
    }
    return(list(globals = globals, packages = character()))
  }
  stop("future_globals must be 'auto', TRUE, FALSE, a character vector, or a named list", call. = FALSE)
}

rducks_mirai_provider <- function(workers = 1L, compute = NULL, dispatcher = TRUE,
                                  max_pending = 64L) {
  workers <- rducks_validate_thread_count(workers, "workers")
  if (is.null(max_pending)) max_pending <- Inf
  if (!is.numeric(max_pending) || length(max_pending) != 1L || is.na(max_pending) || max_pending <= 0) {
    stop("max_pending must be NULL or a positive numeric scalar", call. = FALSE)
  }
  if (is.null(compute)) {
    counter <- .rducks_state$mirai_provider_counter %||% 0L
    counter <- counter + 1L
    .rducks_state$mirai_provider_counter <- counter
    compute <- paste("rducks", Sys.getpid(), counter, sep = "-")
  }
  if (!is.character(compute) || length(compute) != 1L || is.na(compute) || !nzchar(compute)) {
    stop("compute must be a non-empty character scalar", call. = FALSE)
  }
  if (!is.logical(dispatcher) || length(dispatcher) != 1L || is.na(dispatcher)) {
    stop("dispatcher must be TRUE or FALSE", call. = FALSE)
  }

  state <- new.env(parent = emptyenv())
  state$started <- FALSE
  state$compute <- compute
  state$workers <- workers
  state$dispatcher <- dispatcher
  state$max_pending <- max_pending
  state$tasks <- new.env(parent = emptyenv())
  state$submitted <- 0L
  state$completed <- 0L
  state$cancelled <- 0L
  state$errors <- 0L
  state$next_task <- 0L

  provider <- list()

  provider$start <- function(plan = NULL) {
    rducks_mirai_require()
    if (isTRUE(state$started)) return(invisible(provider))
    started_daemons <- FALSE
    ok <- FALSE
    on.exit({
      if (started_daemons && !ok) {
        try(mirai::daemons(0L, .compute = state$compute), silent = TRUE)
      }
    }, add = TRUE)
    mirai::daemons(state$workers, dispatcher = state$dispatcher, .compute = state$compute)
    started_daemons <- TRUE
    setup <- mirai::everywhere({
      library(Rducks)
      assign(".rducks_mirai_registry", new.env(parent = emptyenv()), envir = .GlobalEnv)
      TRUE
    }, .compute = state$compute)
    rducks_mirai_collect_map(setup)
    state$started <- TRUE
    ok <- TRUE
    invisible(provider)
  }

  provider$stop <- function() {
    if (isTRUE(state$started) && requireNamespace("mirai", quietly = TRUE)) {
      try(mirai::daemons(0L, .compute = state$compute), silent = TRUE)
    }
    rm(list = ls(state$tasks, all.names = TRUE), envir = state$tasks)
    state$started <- FALSE
    invisible(provider)
  }

  provider$register_udf <- function(udf_id, udf_name, fun, arg_types, return_type, mode,
                                    null_handling, exception_handling, output_schema_spec,
                                    globals = NULL, packages = character()) {
    rducks_mirai_require()
    if (!isTRUE(state$started)) stop("mirai provider is not started", call. = FALSE)
    if (!is.character(udf_id) || length(udf_id) != 1L || is.na(udf_id) || !nzchar(udf_id)) {
      stop("udf_id must be a non-empty character scalar", call. = FALSE)
    }
    mode <- rducks_match_mode(mode)
    packages <- unique(c("Rducks", packages %||% character()))
    reg <- mirai::everywhere({
      if (!exists(".rducks_mirai_registry", envir = .GlobalEnv, inherits = FALSE)) {
        assign(".rducks_mirai_registry", new.env(parent = emptyenv()), envir = .GlobalEnv)
      }
      registry <- get(".rducks_mirai_registry", envir = .GlobalEnv, inherits = FALSE)
      for (pkg in packages) {
        suppressPackageStartupMessages(require(pkg, character.only = TRUE))
      }
      if (length(globals)) {
        list2env(globals, envir = .GlobalEnv)
      }
      assign(
        udf_id,
        list(
          udf_name = udf_name,
          fun = fun,
          arg_types = arg_types,
          return_type = return_type,
          mode = mode,
          null_handling = null_handling,
          exception_handling = exception_handling,
          output_schema_spec = output_schema_spec
        ),
        envir = registry
      )
      TRUE
    }, udf_id = udf_id, udf_name = udf_name, fun = fun, arg_types = arg_types,
    return_type = return_type, mode = mode, null_handling = null_handling,
    exception_handling = exception_handling, output_schema_spec = output_schema_spec,
    globals = globals %||% list(), packages = packages, .compute = state$compute)
    rducks_mirai_collect_map(reg)
    invisible(udf_id)
  }

  provider$submit <- function(udf_id, chunk_id, row_count, input_ipc_payload, timeout_ms = NULL) {
    rducks_mirai_require()
    if (!isTRUE(state$started)) stop("mirai provider is not started", call. = FALSE)
    if (!is.raw(input_ipc_payload)) stop("input_ipc_payload must be raw Arrow IPC bytes", call. = FALSE)
    if (length(ls(state$tasks, all.names = TRUE)) >= state$max_pending) {
      stop("Rducks mirai provider pending task limit reached", call. = FALSE)
    }
    state$next_task <- state$next_task + 1L
    task_id <- paste("mirai-task", state$next_task, sep = "-")
    task <- mirai::mirai({
      tryCatch({
        if (!exists(".rducks_mirai_registry", envir = .GlobalEnv, inherits = FALSE)) {
          stop("unknown Rducks mirai UDF id: ", udf_id, call. = FALSE)
        }
        registry <- get(".rducks_mirai_registry", envir = .GlobalEnv, inherits = FALSE)
        if (!exists(udf_id, envir = registry, inherits = FALSE)) {
          stop("unknown Rducks mirai UDF id: ", udf_id, call. = FALSE)
        }
        rec <- get(udf_id, envir = registry, inherits = FALSE)
        worker_eval <- utils::getFromNamespace("rducks_future_worker_eval_arrow_ipc_chunk", "Rducks")
        output <- worker_eval(
          input_payload = input_ipc_payload,
          output_schema_spec = rec$output_schema_spec,
          n = row_count,
          fun = rec$fun,
          arg_types = rec$arg_types,
          return_type = rec$return_type,
          null_handling = rec$null_handling,
          exception_handling = rec$exception_handling,
          mode = rec$mode
        )
        list(
          task_id = task_id,
          udf_id = udf_id,
          chunk_id = chunk_id,
          status = "ok",
          output_ipc_payload = output,
          worker_pid = Sys.getpid()
        )
      }, error = function(e) {
        list(
          task_id = task_id,
          udf_id = udf_id,
          chunk_id = chunk_id,
          status = "error",
          error_message = conditionMessage(e),
          worker_pid = Sys.getpid()
        )
      })
    }, .args = list(
      task_id = task_id,
      udf_id = udf_id,
      chunk_id = chunk_id,
      row_count = as.integer(row_count),
      input_ipc_payload = input_ipc_payload
    ), .timeout = timeout_ms, .compute = state$compute)
    assign(task_id, task, envir = state$tasks)
    state$submitted <- state$submitted + 1L
    task_id
  }

  provider$collect_many <- function(task_ids, timeout = NULL) {
    rducks_mirai_require()
    task_ids <- as.character(task_ids)
    if (anyDuplicated(task_ids)) {
      stop("task_ids must not contain duplicates", call. = FALSE)
    }
    deadline <- if (is.null(timeout)) Inf else unclass(Sys.time()) + as.numeric(timeout)
    tasks <- lapply(task_ids, function(task_id) {
      if (!exists(task_id, envir = state$tasks, inherits = FALSE)) {
        stop("unknown Rducks mirai task id: ", task_id, call. = FALSE)
      }
      get(task_id, envir = state$tasks, inherits = FALSE)
    })
    collect_one <- function(i) {
      task_id <- task_ids[[i]]
      value <- tryCatch(
        mirai::call_mirai(tasks[[i]])$data,
        error = function(e) structure(
          list(message = conditionMessage(e)),
          class = "rducks_mirai_collect_error"
        )
      )
      if (exists(task_id, envir = state$tasks, inherits = FALSE)) {
        rm(list = task_id, envir = state$tasks)
      }
      state$completed <- state$completed + 1L
      if (inherits(value, "rducks_mirai_collect_error")) {
        state$errors <- state$errors + 1L
        list(task_id = task_id, status = "error", error_message = value$message)
      } else if (inherits(value, "errorValue")) {
        state$errors <- state$errors + 1L
        list(task_id = task_id, status = "error", error_message = as.character(value))
      } else {
        if (identical(value$status, "error")) state$errors <- state$errors + 1L
        value
      }
    }

    repeat {
      unresolved <- vapply(tasks, mirai::unresolved, logical(1))
      if (!any(unresolved)) break
      if (is.finite(deadline) && unclass(Sys.time()) >= deadline) {
        ready <- which(!unresolved)
        if (length(ready)) invisible(lapply(ready, collect_one))
        for (i in which(unresolved)) {
          task_id <- task_ids[[i]]
          try(mirai::stop_mirai(tasks[[i]]), silent = TRUE)
          if (exists(task_id, envir = state$tasks, inherits = FALSE)) {
            rm(list = task_id, envir = state$tasks)
          }
        }
        state$errors <- state$errors + sum(unresolved)
        stop("Rducks mirai provider timed out waiting for task ", task_ids[[which(unresolved)[[1L]]]], call. = FALSE)
      }
      Sys.sleep(0.001)
    }

    lapply(seq_along(task_ids), collect_one)
  }

  provider$collect_any <- function(max_results = Inf, timeout = NULL, task_ids = NULL) {
    selected <- if (is.null(task_ids)) NULL else unique(as.character(task_ids))
    pending <- ls(state$tasks, all.names = TRUE)
    if (!is.null(selected)) pending <- pending[pending %in% selected]
    if (!length(pending)) return(list())
    deadline <- if (is.null(timeout)) Inf else unclass(Sys.time()) + as.numeric(timeout)
    repeat {
      pending <- ls(state$tasks, all.names = TRUE)
      if (!is.null(selected)) pending <- pending[pending %in% selected]
      if (!length(pending)) return(list())
      ready <- pending[!vapply(pending, function(id) mirai::unresolved(get(id, envir = state$tasks)), logical(1))]
      if (length(ready)) {
        ready <- utils::head(ready, max_results)
        return(provider$collect_many(ready, timeout = 0))
      }
      if (is.finite(deadline) && unclass(Sys.time()) >= deadline) return(list())
      Sys.sleep(0.001)
    }
  }

  provider$cancel <- function(task_ids) {
    rducks_mirai_require()
    for (task_id in as.character(task_ids)) {
      if (exists(task_id, envir = state$tasks, inherits = FALSE)) {
        try(mirai::stop_mirai(get(task_id, envir = state$tasks)), silent = TRUE)
        rm(list = task_id, envir = state$tasks)
        state$cancelled <- state$cancelled + 1L
      }
    }
    invisible(provider)
  }

  provider$stats <- function() {
    data.frame(
      provider = "mirai",
      compute = state$compute,
      workers = state$workers,
      max_pending = state$max_pending,
      started = isTRUE(state$started),
      submitted = state$submitted,
      completed = state$completed,
      cancelled = state$cancelled,
      errors = state$errors,
      pending = length(ls(state$tasks, all.names = TRUE))
    )
  }

  provider
}
