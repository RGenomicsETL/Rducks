rducks_nanoarrow_pointer_is_valid <- function(ptr) {
  isTRUE(tryCatch(nanoarrow::nanoarrow_pointer_is_valid(ptr), error = function(e) FALSE))
}

rducks_ipc_worker_eval_arrow_ipc_chunk <- function(input_payload,
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

rducks_ipc_worker_eval_vectorized_chunk <- function(input_payload,
                                                    output_schema_spec,
                                                    n,
                                                    fun,
                                                    arg_types,
                                                    return_type,
                                                    null_handling,
                                                    exception_handling) {
  rducks_ipc_worker_eval_arrow_ipc_chunk(
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

rducks_ipc_globals_for_function <- function(fun) {
  if (!requireNamespace("codetools", quietly = TRUE)) {
    stop("ipc_globals = 'auto' requires the codetools package", call. = FALSE)
  }
  globals <- list()
  packages <- character()
  queue <- list(fun)
  seen <- character()

  while (length(queue)) {
    current <- queue[[1L]]
    queue <- queue[-1L]
    current_key <- paste0(typeof(current), "@", .Call(RDUCKS_sexp_addr, current))
    if (current_key %in% seen) next
    seen <- c(seen, current_key)

    found <- codetools::findGlobals(current, merge = FALSE)
    names <- unique(c(found$variables %||% character(), found$functions %||% character()))
    env <- environment(current) %||% parent.frame()
    for (name in names) {
      if (name %in% c("...", "::", ":::", "{", "(", "if", "for", "while", "repeat", "function")) next
      binding_env <- rducks_ipc_find_binding_env(name, env)
      if (is.null(binding_env)) next

      pkg <- rducks_ipc_package_env_name(binding_env)
      if (!is.na(pkg)) {
        if (!pkg %in% c("base", "Autoloads")) packages <- unique(c(packages, pkg))
        next
      }

      value <- get(name, envir = binding_env, inherits = FALSE)
      if (!name %in% names(globals)) globals[[name]] <- value
      if (is.function(value)) queue[[length(queue) + 1L]] <- value
    }
  }

  list(globals = globals, packages = packages)
}

rducks_ipc_worker_globals <- function(fun, globals) {
  if (identical(globals, "auto") || isTRUE(globals)) {
    return(rducks_ipc_globals_for_function(fun))
  }
  if (identical(globals, FALSE) || is.null(globals)) {
    return(list(globals = list(), packages = character()))
  }
  if (is.character(globals)) {
    env <- environment(fun) %||% parent.frame()
    values <- mget(globals, envir = env, inherits = TRUE, ifnotfound = list(NULL))
    missing <- globals[vapply(values, is.null, logical(1))]
    if (length(missing)) {
      stop("ipc_globals names not found in the UDF environment: ", paste(missing, collapse = ", "), call. = FALSE)
    }
    return(list(globals = values, packages = character()))
  }
  if (is.list(globals)) {
    if (length(globals) && (is.null(names(globals)) || any(!nzchar(names(globals))))) {
      stop("ipc_globals supplied as a list must be named", call. = FALSE)
    }
    return(list(globals = globals, packages = character()))
  }
  stop("ipc_globals must be 'auto', TRUE, FALSE, a character vector, or a named list", call. = FALSE)
}
