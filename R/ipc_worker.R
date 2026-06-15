rducks_ipc_worker_check_n <- function(n) {
  if (!is.numeric(n) || length(n) != 1L || is.na(n) || !is.finite(n) || n < 0 || n != floor(n) ||
      n > .Machine$integer.max) {
    stop("Rducks IPC row count must be a non-negative integer scalar", call. = FALSE)
  }
  as.integer(n)
}

rducks_ipc_worker_eval_quack_chunk <- function(input_payload,
                                               n,
                                               fun,
                                               arg_types,
                                               return_type,
                                               null_handling,
                                               exception_handling,
                                               mode,
                                               dynamic_arg_tokens = NULL) {
  n <- rducks_ipc_worker_check_n(n)
  mode <- rducks_match_mode(mode)
  arg_types <- rducks_resolve_dynamic_arg_types(arg_types, dynamic_arg_tokens)
  decoded <- rducks_wire_decode_values(arg_types, input_payload)
  if (!identical(decoded$rows, n)) {
    stop("Rducks wire payload row count disagrees with the task row count", call. = FALSE)
  }
  prepared <- rducks_native_prepared_inputs(arg_types, decoded$values, n)
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
  rducks_quack_results_payload(return_type, results, n)
}

rducks_ipc_worker_eval_vectorized_chunk <- function(input_payload,
                                                    n,
                                                    fun,
                                                    arg_types,
                                                    return_type,
                                                    null_handling,
                                                    exception_handling) {
  rducks_ipc_worker_eval_quack_chunk(
    input_payload = input_payload,
    n = n,
    fun = fun,
    arg_types = arg_types,
    return_type = return_type,
    null_handling = null_handling,
    exception_handling = exception_handling,
    mode = "vectorized"
  )
}

rducks_ipc_find_binding_env <- function(name, env) {
  while (!identical(env, emptyenv())) {
    if (exists(name, envir = env, inherits = FALSE)) return(env)
    env <- parent.env(env)
  }
  NULL
}

rducks_ipc_package_env_name <- function(env) {
  env_name <- environmentName(env)
  if (!nzchar(env_name)) return(NA_character_)
  if (startsWith(env_name, "package:")) return(sub("^package:", "", env_name))
  if (startsWith(env_name, "namespace:")) return(sub("^namespace:", "", env_name))
  if (env_name %in% c("base", "Autoloads")) return(env_name)
  NA_character_
}

rducks_ipc_ignored_global_name <- function(name) {
  name %in% c("...", "::", ":::", "{", "(", "if", "for", "while", "repeat", "function")
}

rducks_ipc_globals_from_globals_package <- function(fun) {
  if (!requireNamespace("globals", quietly = TRUE) ||
      !"method" %in% names(formals(globals::findGlobals))) {
    return(NULL)
  }
  found <- globals::globalsOf(
    fun,
    envir = environment(fun) %||% .GlobalEnv,
    method = "dfs",
    recursive = TRUE,
    mustExist = FALSE,
    unlist = TRUE
  )

  where <- attr(found, "where", exact = TRUE) %||% list()
  globals <- list()
  packages <- character()
  for (name in names(found)) {
    if (rducks_ipc_ignored_global_name(name)) next
    binding_env <- where[[name]]
    if (is.null(binding_env)) next
    pkg <- rducks_ipc_package_env_name(binding_env)
    if (!is.na(pkg)) {
      if (!pkg %in% c("base", "Autoloads")) packages <- unique(c(packages, pkg))
      next
    }
    globals[name] <- list(found[[name]])
  }
  list(globals = globals, packages = unique(packages))
}

rducks_ipc_find_globals_codetools <- function(fun) {
  if (!requireNamespace("codetools", quietly = TRUE)) {
    stop("ipc_globals = 'auto' requires the globals or codetools package", call. = FALSE)
  }
  found <- codetools::findGlobals(fun, merge = FALSE)
  unique(c(found$variables %||% character(), found$functions %||% character()))
}

rducks_ipc_globals_for_function_codetools <- function(fun) {
  globals <- list()
  packages <- character()
  queue <- list(fun)
  queue_pos <- 1L
  seen <- list()
  seen_globals <- new.env(parent = emptyenv())

  while (queue_pos <= length(queue)) {
    current <- queue[[queue_pos]]
    queue_pos <- queue_pos + 1L
    if (length(seen) && any(vapply(seen, identical, logical(1), current))) next
    seen[[length(seen) + 1L]] <- current

    names <- rducks_ipc_find_globals_codetools(current)
    env <- environment(current) %||% .GlobalEnv
    for (name in names) {
      if (rducks_ipc_ignored_global_name(name)) next
      binding_env <- rducks_ipc_find_binding_env(name, env)
      if (is.null(binding_env)) next

      pkg <- rducks_ipc_package_env_name(binding_env)
      if (!is.na(pkg)) {
        if (!pkg %in% c("base", "Autoloads")) packages <- unique(c(packages, pkg))
        next
      }

      value <- get(name, envir = binding_env, inherits = FALSE)
      if (!exists(name, envir = seen_globals, inherits = FALSE)) {
        globals[[name]] <- value
        assign(name, TRUE, envir = seen_globals)
      }
      if (is.function(value)) queue[[length(queue) + 1L]] <- value
    }
  }

  list(globals = globals, packages = unique(packages))
}

rducks_ipc_globals_for_function <- function(fun) {
  if (!is.function(fun)) {
    stop("ipc_globals = 'auto' requires an R function", call. = FALSE)
  }
  globals <- rducks_ipc_globals_from_globals_package(fun)
  if (!is.null(globals)) return(globals)
  rducks_ipc_globals_for_function_codetools(fun)
}

rducks_ipc_format_bytes <- function(bytes) {
  bytes <- as.numeric(bytes)
  units <- c("bytes", "KiB", "MiB", "GiB")
  unit <- 1L
  while (is.finite(bytes) && bytes >= 1024 && unit < length(units)) {
    bytes <- bytes / 1024
    unit <- unit + 1L
  }
  if (unit == 1L) {
    return(paste0(format(round(bytes), trim = TRUE, scientific = FALSE), " ", units[[unit]]))
  }
  paste0(format(round(bytes, 1), trim = TRUE, scientific = FALSE), " ", units[[unit]])
}

rducks_ipc_byte_option <- function(name, default, what) {
  value <- getOption(name, default)
  if (is.null(value) || identical(value, FALSE)) return(Inf)
  value <- suppressWarnings(as.numeric(value))
  if (length(value) != 1L || is.na(value) || value < 0 || (!is.finite(value) && !is.infinite(value))) {
    stop(what, " must be a non-negative finite byte count, Inf, NULL, or FALSE", call. = FALSE)
  }
  value
}

rducks_ipc_globals_serialized_size <- function(globals, what) {
  length(tryCatch(
    serialize(globals, NULL, xdr = FALSE),
    error = function(e) {
      stop("failed to serialize ", what, ": ", conditionMessage(e), call. = FALSE)
    }
  ))
}

rducks_ipc_share_globals <- function(globals, share = "none") {
  share <- rducks_validate_ipc_globals_share(share)
  if (identical(share, "none") || !length(globals)) return(globals)
  if (!requireNamespace("mori", quietly = TRUE)) {
    stop("ipc_globals_share = 'mori' requires the mori package", call. = FALSE)
  }
  out <- globals
  for (name in names(globals)) {
    out[name] <- list(mori::share(globals[[name]]))
  }
  out
}

rducks_ipc_check_auto_globals_size <- function(globals, what = "automatically discovered ipc_globals") {
  bytes <- rducks_ipc_globals_serialized_size(globals, what)
  max_bytes <- rducks_ipc_byte_option(
    "rducks.ipc_globals.max_bytes",
    Inf,
    "option rducks.ipc_globals.max_bytes"
  )
  warn_bytes <- rducks_ipc_byte_option(
    "rducks.ipc_globals.warn_bytes",
    8 * 1024^2,
    "option rducks.ipc_globals.warn_bytes"
  )

  if (is.finite(max_bytes) && bytes > max_bytes) {
    stop(
      "ipc_globals = 'auto' captured ", rducks_ipc_format_bytes(bytes),
      ", which exceeds option rducks.ipc_globals.max_bytes = ",
      rducks_ipc_format_bytes(max_bytes),
      ". Use explicit ipc_globals, reduce the UDF closure environment, or raise the limit.",
      call. = FALSE
    )
  }
  if (is.finite(warn_bytes) && bytes > warn_bytes) {
    warning(
      "ipc_globals = 'auto' captured ", rducks_ipc_format_bytes(bytes),
      " of globals to broadcast to each IPC worker. Use explicit ipc_globals ",
      "or set option rducks.ipc_globals.warn_bytes to adjust this warning.",
      call. = FALSE
    )
  }
  invisible(bytes)
}

rducks_ipc_worker_globals <- function(fun, globals, share = "none") {
  share <- rducks_validate_ipc_globals_share(share)
  if (identical(globals, "auto") || isTRUE(globals)) {
    worker_globals <- rducks_ipc_globals_for_function(fun)
    worker_globals$globals <- rducks_ipc_share_globals(worker_globals$globals, share)
    if (identical(share, "mori") && length(worker_globals$globals)) {
      worker_globals$packages <- unique(c(worker_globals$packages, "mori"))
    }
    rducks_ipc_check_auto_globals_size(worker_globals$globals)
    return(worker_globals)
  }
  if (identical(globals, FALSE) || is.null(globals)) {
    return(list(globals = list(), packages = character()))
  }
  if (is.character(globals)) {
    globals <- unique(globals)
    if (!is.function(fun)) stop("ipc_globals character names require an R function", call. = FALSE)
    env <- environment(fun) %||% .GlobalEnv
    found <- vapply(globals, exists, logical(1), envir = env, inherits = TRUE)
    missing <- globals[!found]
    if (length(missing)) {
      stop("ipc_globals names not found in the UDF environment: ", paste(missing, collapse = ", "), call. = FALSE)
    }
    values <- mget(globals, envir = env, inherits = TRUE)
    values <- rducks_ipc_share_globals(values, share)
    packages <- if (identical(share, "mori") && length(values)) "mori" else character()
    return(list(globals = values, packages = packages))
  }
  if (is.list(globals)) {
    names <- names(globals)
    if (length(globals) && (is.null(names) || anyNA(names) || any(!nzchar(names)) || anyDuplicated(names))) {
      stop("ipc_globals supplied as a list must have unique non-empty names", call. = FALSE)
    }
    globals <- rducks_ipc_share_globals(globals, share)
    packages <- if (identical(share, "mori") && length(globals)) "mori" else character()
    return(list(globals = globals, packages = packages))
  }
  stop("ipc_globals must be 'auto', TRUE, FALSE, a character vector, or a named list", call. = FALSE)
}
