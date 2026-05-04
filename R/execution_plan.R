rducks_plan_marshalling <- function(x) {
  match.arg(x, c("arrow_r", "arrow_c", "arrow_ipc"))
}

rducks_plan_concurrency <- function(x) {
  match.arg(x, c("serial", "inproc_concurrent", "multiprocess_parallel"))
}

rducks_plan_backend <- function(concurrency) {
  switch(
    concurrency,
    serial = "single",
    inproc_concurrent = "concurrent_inproc",
    multiprocess_parallel = "multiprocess_parallel",
    stop("unsupported Rducks execution-plan concurrency: ", concurrency, call. = FALSE)
  )
}

rducks_plan_serialization <- function(marshalling) {
  if (identical(marshalling, "arrow_ipc")) "arrow_ipc" else "none"
}

rducks_plan_implemented <- function(marshalling, concurrency) {
  (marshalling %in% c("arrow_r", "arrow_c") &&
    concurrency %in% c("serial", "inproc_concurrent")) ||
    (identical(marshalling, "arrow_ipc") && identical(concurrency, "multiprocess_parallel"))
}

rducks_plan_supported_call_shapes <- function(marshalling, concurrency) {
  if (!rducks_plan_implemented(marshalling, concurrency)) {
    return(character())
  }
  switch(
    marshalling,
    arrow_r = c("scalar", "vectorized"),
    arrow_c = c("scalar", "vectorized"),
    arrow_ipc = c("scalar", "vectorized"),
    character()
  )
}

rducks_future_options <- function(globals = TRUE,
                                  packages = NULL,
                                  seed = FALSE,
                                  stdout = FALSE,
                                  conditions = "condition",
                                  timeout = NULL) {
  if (!(isTRUE(globals) || identical(globals, FALSE) || is.character(globals) || is.list(globals))) {
    stop("future_globals must be TRUE, FALSE, a character vector, or a named list", call. = FALSE)
  }
  if (!is.null(packages) && !is.character(packages)) {
    stop("future_packages must be NULL or a character vector", call. = FALSE)
  }
  if (!is.logical(stdout) || length(stdout) != 1L || is.na(stdout)) {
    stop("future_stdout must be TRUE or FALSE", call. = FALSE)
  }
  if (is.null(conditions)) {
    conditions <- character()
  }
  if (!is.character(conditions)) {
    stop("future_conditions must be NULL or a character vector", call. = FALSE)
  }
  if (!is.null(timeout) && (!is.numeric(timeout) || length(timeout) != 1L || is.na(timeout) || timeout < 0)) {
    stop("future_timeout must be NULL or a non-negative numeric scalar", call. = FALSE)
  }
  list(
    globals = globals,
    packages = unique(c("Rducks", packages)),
    seed = seed,
    stdout = stdout,
    conditions = conditions,
    timeout = timeout
  )
}

rducks_validate_execution_plan_values <- function(marshalling, concurrency) {
  if (identical(marshalling, "arrow_ipc") && !identical(concurrency, "multiprocess_parallel")) {
    stop("marshalling = 'arrow_ipc' requires concurrency = 'multiprocess_parallel'", call. = FALSE)
  }
  if (!identical(marshalling, "arrow_ipc") && identical(concurrency, "multiprocess_parallel")) {
    stop("concurrency = 'multiprocess_parallel' requires marshalling = 'arrow_ipc'", call. = FALSE)
  }
  invisible(TRUE)
}

#' Define an Rducks execution plan
#'
#' An execution plan is connection/session policy: it says how Rducks should
#' marshal DuckDB chunks and what concurrency model is allowed. It is separate
#' from UDF registration semantics such as scalar versus vectorized call shape,
#' argument/return types, NULL handling, error handling, and side effects.
#'
#' `arrow_r + serial` is the reference implementation used for conformance.
#' Other plans must be explicitly implemented and validated against that
#' reference; Rducks does not silently fall back from one plan to another.
#'
#' @param marshalling Chunk marshalling implementation. `"arrow_r"` uses Arrow C
#'   Data plus nanoarrow/R materialization and is the reference implementation.
#'   `"arrow_c"` uses native C/DuckDB-vector materialization for supported
#'   plans. `"arrow_ipc"` uses Arrow IPC bytes as the explicit task/result
#'   payload for the Future-based multiprocess path.
#' @param concurrency Concurrency contract. `"serial"` evaluates one chunk at a
#'   time in the calling process. `"inproc_concurrent"` allows in-process DuckDB
#'   callback concurrency while keeping R API work serialized on the recorded R
#'   execution lane. `"multiprocess_parallel"` uses the current `future` backend
#'   for process-isolated chunk work and requires `marshalling = "arrow_ipc"`.
#' @param future_globals,future_packages,future_seed,future_stdout,future_conditions,future_timeout
#'   Options forwarded to `future::future()` for `arrow_ipc +
#'   multiprocess_parallel` registrations. Use `future_packages` for packages
#'   that workers should attach and `future_globals` when automatic global
#'   capture needs help.
#' @return An object of class `rducks_execution_plan`.
#' @export
rducks_execution_plan <- function(marshalling = c("arrow_r", "arrow_c", "arrow_ipc"),
                                  concurrency = c("serial", "inproc_concurrent", "multiprocess_parallel"),
                                  future_globals = TRUE,
                                  future_packages = NULL,
                                  future_seed = FALSE,
                                  future_stdout = FALSE,
                                  future_conditions = "condition",
                                  future_timeout = NULL) {
  marshalling <- rducks_plan_marshalling(marshalling)
  concurrency <- rducks_plan_concurrency(concurrency)
  rducks_validate_execution_plan_values(marshalling, concurrency)
  backend <- rducks_plan_backend(concurrency)
  serialization <- rducks_plan_serialization(marshalling)
  implemented <- rducks_plan_implemented(marshalling, concurrency)
  supported_call_shapes <- rducks_plan_supported_call_shapes(marshalling, concurrency)
  future_options <- if (identical(marshalling, "arrow_ipc")) {
    rducks_future_options(
      globals = future_globals,
      packages = future_packages,
      seed = future_seed,
      stdout = future_stdout,
      conditions = future_conditions,
      timeout = future_timeout
    )
  } else {
    NULL
  }
  structure(
    list(
      marshalling = marshalling,
      concurrency = concurrency,
      plan_id = paste(marshalling, concurrency, sep = "+"),
      reference = identical(marshalling, "arrow_r") && identical(concurrency, "serial"),
      implemented = implemented,
      supported_call_shapes = supported_call_shapes,
      backend = backend,
      serialization = serialization,
      future_options = future_options,
      in_process = !identical(concurrency, "multiprocess_parallel"),
      uses_r_thread = TRUE
    ),
    class = "rducks_execution_plan"
  )
}

#' @export
print.rducks_execution_plan <- function(x, ...) {
  cat("<rducks_execution_plan>\n")
  cat("  plan_id:     ", x$plan_id, "\n", sep = "")
  cat("  marshalling: ", x$marshalling, "\n", sep = "")
  cat("  concurrency: ", x$concurrency, "\n", sep = "")
  cat("  reference:   ", if (isTRUE(x$reference)) "yes" else "no", "\n", sep = "")
  cat("  implemented: ", if (isTRUE(x$implemented)) "yes" else "no", "\n", sep = "")
  cat("  call shapes: ", paste(x$supported_call_shapes, collapse = ", "), "\n", sep = "")
  invisible(x)
}

rducks_as_execution_plan <- function(plan) {
  if (inherits(plan, "rducks_execution_plan")) {
    return(plan)
  }
  if (is.character(plan) && length(plan) == 1L) {
    return(switch(
      plan,
      reference = rducks_execution_plan("arrow_r", "serial"),
      serial = rducks_execution_plan("arrow_r", "serial"),
      inproc_concurrent = rducks_execution_plan("arrow_r", "inproc_concurrent"),
      arrow_r = rducks_execution_plan("arrow_r", "serial"),
      arrow_c = rducks_execution_plan("arrow_c", "serial"),
      stop("unknown Rducks execution plan shortcut: ", plan, call. = FALSE)
    ))
  }
  stop("plan must be an rducks_execution_plan object", call. = FALSE)
}

rducks_connection_plan_store <- function() {
  store <- .rducks_state$connection_plans
  if (is.null(store)) {
    store <- new.env(parent = emptyenv())
    .rducks_state$connection_plans <- store
  }
  store
}

rducks_connection_key <- function(con) {
  .Call(RDUCKS_sexp_addr, con)
}

rducks_store_connection_plan <- function(con, plan) {
  assign(rducks_connection_key(con), plan, envir = rducks_connection_plan_store())
  invisible(plan)
}

#' Inspect the current Rducks execution plan
#'
#' Returns the R-side execution plan recorded for a DuckDB connection. If no plan
#' has been recorded yet, this returns the reference plan `arrow_r + serial`.
#'
#' @param con A `duckdb_connection`.
#' @return An object of class `rducks_execution_plan`.
#' @export
rducks_current_execution_plan <- function(con) {
  rducks_assert_duckdb_connection(con)
  key <- rducks_connection_key(con)
  store <- rducks_connection_plan_store()
  if (exists(key, envir = store, inherits = FALSE)) {
    get(key, envir = store, inherits = FALSE)
  } else {
    rducks_execution_plan("arrow_r", "serial")
  }
}

rducks_assert_execution_plan_implemented <- function(plan) {
  if (!isTRUE(plan$implemented)) {
    stop("Rducks execution plan is not implemented yet: ", plan$plan_id, call. = FALSE)
  }
  invisible(TRUE)
}

rducks_arrow_ipc_mapping_supported <- function(type) {
  type <- if (inherits(type, "rducks_type")) type else rducks_type_object(type)
  kind <- rducks_type_kind(type)
  if (identical(kind, "enum")) {
    return(FALSE)
  }
  children <- rducks_type_children(type)
  if (length(children)) {
    return(all(vapply(children, rducks_arrow_ipc_mapping_supported, logical(1))))
  }
  TRUE
}

rducks_arrow_ipc_unsupported_types <- function(type) {
  type <- if (inherits(type, "rducks_type")) type else rducks_type_object(type)
  if (rducks_arrow_ipc_mapping_supported(type)) {
    return(character())
  }
  children <- rducks_type_children(type)
  if (length(children)) {
    out <- unique(unlist(lapply(children, rducks_arrow_ipc_unsupported_types), use.names = FALSE))
    if (length(out)) return(out)
  }
  rducks_type_duckdb_sql(type)
}

rducks_validate_execution_plan_for_registration <- function(plan, spec) {
  rducks_assert_execution_plan_implemented(plan)
  if (!identical(spec$mode, "scalar") && !identical(spec$mode, "vectorized")) {
    stop("unknown Rducks UDF call shape: ", spec$mode, call. = FALSE)
  }
  if (!spec$mode %in% plan$supported_call_shapes) {
    stop(
      "Rducks execution plan ", plan$plan_id,
      " does not support mode = '", spec$mode, "'",
      call. = FALSE
    )
  }
  if (identical(plan$marshalling, "arrow_ipc")) {
    unsupported <- unique(unlist(lapply(c(spec$arg_types, list(spec$return_type)), rducks_arrow_ipc_unsupported_types), use.names = FALSE))
    unsupported <- unsupported[nzchar(unsupported)]
    if (length(unsupported)) {
      stop(
        "Rducks execution plan ", plan$plan_id,
        " cannot use Arrow IPC marshalling for: ",
        paste(unsupported, collapse = ", "),
        call. = FALSE
      )
    }
  }
  if (identical(spec$mode, "vectorized") && !length(spec$arg_types)) {
    stop("mode = 'vectorized' currently requires at least one declared argument", call. = FALSE)
  }
  invisible(TRUE)
}

rducks_plan_native_evaluator_token <- function(plan, mode = "scalar") {
  mode <- rducks_match_mode(mode)
  switch(
    plan$marshalling,
    arrow_r = "R",
    arrow_c = if (identical(mode, "vectorized")) "RCV" else "RC",
    arrow_ipc = "RIPC",
    stop("unsupported Rducks execution-plan marshalling: ", plan$marshalling, call. = FALSE)
  )
}

