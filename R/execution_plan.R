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
  marshalling %in% c("arrow_r", "arrow_c") &&
    concurrency %in% c("serial", "inproc_concurrent")
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
#'   plans. `"arrow_ipc"` reserves owned Arrow IPC bytes as the future
#'   multiprocess transport boundary.
#' @param concurrency Concurrency contract. `"serial"` evaluates one chunk at a
#'   time in the calling process. `"inproc_concurrent"` allows in-process DuckDB
#'   callback concurrency while keeping R API work serialized on the recorded R
#'   execution lane. `"multiprocess_parallel"` is the future process-isolated
#'   chunk-parallel plan and requires `marshalling = "arrow_ipc"`.
#' @return An object of class `rducks_execution_plan`.
#' @export
rducks_execution_plan <- function(marshalling = c("arrow_r", "arrow_c", "arrow_ipc"),
                                  concurrency = c("serial", "inproc_concurrent", "multiprocess_parallel")) {
  marshalling <- rducks_plan_marshalling(marshalling)
  concurrency <- rducks_plan_concurrency(concurrency)
  rducks_validate_execution_plan_values(marshalling, concurrency)
  backend <- rducks_plan_backend(concurrency)
  serialization <- rducks_plan_serialization(marshalling)
  implemented <- rducks_plan_implemented(marshalling, concurrency)
  structure(
    list(
      marshalling = marshalling,
      concurrency = concurrency,
      plan_id = paste(marshalling, concurrency, sep = "+"),
      reference = identical(marshalling, "arrow_r") && identical(concurrency, "serial"),
      implemented = implemented,
      backend = backend,
      serialization = serialization,
      in_process = !identical(concurrency, "multiprocess_parallel"),
      uses_r_thread = !identical(concurrency, "multiprocess_parallel")
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

rducks_plan_eval_mode <- function(plan, mode) {
  if (identical(plan$marshalling, "arrow_r")) {
    return("R")
  }
  if (identical(plan$marshalling, "arrow_c")) {
    if (identical(mode, "vectorized")) {
      stop("marshalling = 'arrow_c' does not yet support mode = 'vectorized'", call. = FALSE)
    }
    return("RC")
  }
  stop("marshalling = 'arrow_ipc' is not implemented for local UDF registration yet", call. = FALSE)
}

rducks_current_plan_eval_mode <- function(con, mode) {
  rducks_plan_eval_mode(rducks_current_execution_plan(con), mode)
}

# Backwards-compatible internal helper used by the existing scalar/vectorized
# engines. New code should prefer rducks_execution_plan().
rducks_scalar_execution_plan <- function(concurrency = c("serial", "inproc_concurrent", "multiprocess_parallel", "chunk_concurrent"),
                                         backend = NULL,
                                         serialization = NULL,
                                         marshalling = c("arrow_r", "arrow_c", "arrow_ipc")) {
  concurrency <- match.arg(concurrency)
  if (identical(concurrency, "chunk_concurrent")) {
    concurrency <- if (identical(backend, "serialized")) "multiprocess_parallel" else "inproc_concurrent"
  }
  if (!is.null(backend) && identical(backend, "serialized")) {
    concurrency <- "multiprocess_parallel"
  }
  if (!is.null(serialization) && identical(serialization, "arrow_ipc")) {
    marshalling <- "arrow_ipc"
  } else {
    marshalling <- rducks_plan_marshalling(marshalling)
  }
  rducks_execution_plan(marshalling = marshalling, concurrency = concurrency)
}
