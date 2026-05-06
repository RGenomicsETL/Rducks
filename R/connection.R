#' Locate the built Rducks DuckDB extension
#'
#' @return Character scalar path to `rducks.duckdb_extension`.
#' @export
rducks_extension_path <- function() {
  system.file(
    "rducks_extension",
    "build",
    "rducks.duckdb_extension",
    package = "Rducks",
    mustWork = TRUE
  )
}

#' Enable Rducks on a DuckDB connection
#'
#' Loads the bundled Rducks DuckDB extension. The registration-safe R UDF path
#' requires R API work to happen on the recorded main R thread; pass
#' `threads = "single"` to set `external_threads=1` and `PRAGMA threads=1`
#' explicitly. After registering UDFs, call [rducks_enable_inproc()] to opt into
#' the extension-owned in-process queue.
#'
#' @param con A `duckdb_connection`.
#' @param extension_path Extension path. Defaults to [rducks_extension_path()].
#' @param threads Either `"unchanged"` or `"single"`.
#' @return `con`, invisibly.
#' @export
rducks_enable <- function(con, extension_path = rducks_extension_path(),
                          threads = c("unchanged", "single")) {
  threads <- match.arg(threads)
  rducks_assert_duckdb_connection(con)

  path_sql <- rducks_sql_string(normalizePath(extension_path, mustWork = TRUE))
  DBI::dbExecute(con, sprintf("LOAD %s", path_sql))
  DBI::dbExecute(con, "SET arrow_lossless_conversion=true")

  main_thread_token <- rducks_main_thread_token()
  if (nzchar(main_thread_token)) {
    ok <- DBI::dbGetQuery(
      con,
      sprintf("SELECT rducks_set_main_thread_token(%s) AS ok", rducks_sql_string(main_thread_token))
    )$ok[[1L]]
    if (!isTRUE(ok)) {
      stop("failed to initialize Rducks main-thread guard", call. = FALSE)
    }
  }

  if (identical(threads, "single")) {
    rducks_configure_duckdb_threads(con, threads = 1L, external_threads = 1L)
  }

  rducks_attach_runtime_anchor(con)
  rducks_set_execution_plan(con, rducks_execution_plan("arrow_r", "serial"))
  invisible(con)
}

#' Enable in-process queued R UDF execution
#'
#' Switches a Rducks-enabled DuckDB connection to the in-process queued R UDF
#' backend. This backend preserves R's thread discipline: DuckDB worker-side UDF
#' callbacks submit chunk requests to an extension-owned queue, and the recorded
#' main R thread drains the queue and performs all R API work. This is a
#' same-process scheduling mode, not a performance promise; R function calls are
#' still serialized on the main R thread. This helper changes only the
#' concurrency part of the active execution plan; marshalling stays `arrow_r` or
#' `arrow_c` according to [rducks_set_execution_plan()].
#'
#' Register UDFs while the connection is in the registration-safe
#' configuration, then call `rducks_enable_inproc()` before running queries that
#' should use the queued in-process path. Use `threads`/`external_threads` here
#' to adjust DuckDB's thread settings for queued execution.
#'
#' @param con A `duckdb_connection` already enabled with [rducks_enable()].
#' @param threads Optional positive integer to set with `PRAGMA threads` before
#'   enabling the in-process backend. Use `NULL` to leave unchanged.
#' @param external_threads Optional positive integer to set with
#'   `SET external_threads` before enabling the in-process backend. Use `NULL`
#'   to leave unchanged. For actual DuckDB worker concurrency, keep this smaller
#'   than `threads` (for example `threads = 4, external_threads = 1`).
#' @return `con`, invisibly.
#' @export
rducks_enable_inproc <- function(con, threads = NULL, external_threads = NULL) {
  rducks_assert_duckdb_connection(con)
  current <- rducks_current_execution_plan(con)
  plan <- rducks_execution_plan(current$marshalling, "inproc_concurrent")
  rducks_set_execution_plan(con, plan, threads = threads, external_threads = external_threads)
  invisible(con)
}

#' Disable in-process queued R UDF execution
#'
#' Switches a Rducks-enabled DuckDB connection back to the direct serial backend.
#' Optionally updates DuckDB thread settings at the same time.
#'
#' @param con A `duckdb_connection`.
#' @param threads Optional positive integer to set with `PRAGMA threads`.
#' @param external_threads Optional positive integer to set with
#'   `SET external_threads`. Use `NULL` to leave unchanged.
#' @return `con`, invisibly.
#' @export
rducks_disable_inproc <- function(con, threads = NULL, external_threads = NULL) {
  rducks_assert_duckdb_connection(con)
  current <- rducks_current_execution_plan(con)
  plan <- rducks_execution_plan(current$marshalling, "serial")
  rducks_set_execution_plan(con, plan, threads = threads, external_threads = external_threads)
  invisible(con)
}

#' Detach Rducks connection-local state
#'
#' Detaches Rducks' connection-local R state for `con`. This clears the current
#' default execution plan and releases this connection's R-side runtime anchor.
#' It does not drop DuckDB catalog functions, unregister UDFs, or release
#' native-owned R closures that are still referenced by database-scoped catalog
#' metadata. If sibling DBI connections are attached to the same DuckDB database
#' runtime, their database-scoped Rducks registration metadata remains visible.
#'
#' Call [rducks_enable()] again before using `con` for further Rducks
#' registrations or connection-local plan changes.
#'
#' @param con A `duckdb_connection`.
#' @return `con`, invisibly.
#' @export
rducks_release <- function(con) {
  rducks_assert_duckdb_connection(con)
  # If the extension is still reachable, give native code a safe recorded-main-
  # thread drain point for preserved R objects queued by off-main DuckDB catalog
  # destructors. This is non-destructive: it does not drop functions or release
  # closures still owned by live catalog metadata.
  try(rducks_runtime_token(con, required = FALSE), silent = TRUE)
  rducks_detach_connection_token(con)
  invisible(con)
}

#' @rdname rducks_release
#' @export
rducks_detach <- function(con) {
  rducks_release(con)
}

#' Inspect in-process queue counters
#'
#' Returns diagnostic counters for the extension-owned in-process queue.
#' `submitted` counts requests submitted to the recorded main R thread,
#' `executed` counts requests drained by that thread, and `timeouts` counts
#' requests that were abandoned rather than waiting indefinitely. The
#' `pending_*` and `running_*` columns expose current and maximum queue pressure:
#' pending requests are waiting to be drained by the main R thread, while running
#' requests have been popped by that thread and are executing or collecting.
#' `pending_timeout_ms` is the configured native pending-request timeout. Running requests
#' borrow DuckDB callback-frame input/output storage, so running-timeout
#' cancellation is intentionally not supported and is reported via
#' `running_timeout_supported = FALSE`.
#'
#' @param con A `duckdb_connection`.
#' @return A one-row data frame with queue diagnostic columns.
#' @export
rducks_inproc_stats <- function(con) {
  rducks_assert_duckdb_connection(con)
  DBI::dbGetQuery(
    con,
    paste(
      "SELECT rducks_queue_submitted() AS submitted,",
      "rducks_queue_executed() AS executed,",
      "rducks_queue_timeouts() AS timeouts,",
      "rducks_queue_pending_current() AS pending_current,",
      "rducks_queue_pending_max() AS pending_max,",
      "rducks_queue_running_current() AS running_current,",
      "rducks_queue_running_max() AS running_max,",
      "rducks_queue_pending_timeout_ms() AS pending_timeout_ms,",
      "rducks_queue_running_timeout_supported() AS running_timeout_supported"
    )
  )
}

#' Inspect preserved-object release counters
#'
#' Returns process-local diagnostics for preserved R objects that native DuckDB
#' catalog metadata could not release immediately because destruction happened
#' off the recorded main R thread. Safe main-thread drain points include
#' [rducks_enable()], [rducks_release()], [rducks_register()], UDF execution, and
#' metadata/stat queries.
#'
#' @param con A `duckdb_connection`.
#' @return A one-row data frame with queued, released, failed, and pending
#'   counters.
#' @export
rducks_release_stats <- function(con) {
  rducks_assert_duckdb_connection(con)
  DBI::dbGetQuery(
    con,
    paste(
      "SELECT rducks_release_queue_queued() AS queued,",
      "rducks_release_queue_released() AS released,",
      "rducks_release_queue_failed() AS failed,",
      "rducks_release_queue_pending() AS pending"
    )
  )
}

#' Inspect native runtime registry counters
#'
#' Returns process-local diagnostics for database-scoped native runtime entries
#' and their extension-owned DuckDB connections. The `con` argument is only the
#' enabled DuckDB connection used to reach the diagnostic SQL functions; the
#' counters are process-global, not scoped only to `con`. `active_entries` means
#' entries whose stored database handle has not been marked as a stale registry
#' alias, and `stale_entries` means entries retained only to avoid reusing an old
#' raw database address. DuckDB's C extension API does not currently provide a
#' clean database-close callback for this package, so these counters are
#' accounting diagnostics rather than deterministic lifetime guarantees.
#'
#' @param con An enabled `duckdb_connection`.
#' @return A one-row data frame with runtime registry and connection counters.
#' @export
rducks_runtime_stats <- function(con) {
  rducks_assert_duckdb_connection(con)
  DBI::dbGetQuery(
    con,
    paste(
      "SELECT rducks_runtime_registry_entries() AS registry_entries,",
      "rducks_runtime_active_entries() AS active_entries,",
      "rducks_runtime_stale_entries() AS stale_entries,",
      "rducks_runtime_entries_created() AS entries_created,",
      "rducks_runtime_stale_aliases() AS stale_aliases,",
      "rducks_runtime_connections_opened() AS connections_opened,",
      "rducks_runtime_connections_closed() AS connections_closed,",
      "rducks_runtime_connection_open_failed() AS connection_open_failed,",
      "rducks_runtime_queue_init_failed() AS queue_init_failed"
    )
  )
}

#' Exercise the in-process queue
#'
#' Runs a native self-test that submits `n` requests from worker threads to the
#' extension-owned main-thread queue and drains them on the recorded main R
#' thread. This validates the queue/condition-variable path without calling an R
#' UDF.
#'
#' @param con A `duckdb_connection`.
#' @param n Number of queue round trips to run.
#' @return Integer-like numeric scalar: number of requests completed.
#' @export
rducks_inproc_self_test <- function(con, n = 1000L) {
  rducks_assert_duckdb_connection(con)
  n <- rducks_validate_thread_count(n, "n")
  DBI::dbGetQuery(
    con,
    sprintf("SELECT rducks_queue_self_test(%s::UBIGINT) AS n", as.character(n))
  )$n[[1L]]
}

rducks_sql_string <- function(x) {
  sprintf("'%s'", gsub("'", "''", x, fixed = TRUE))
}

rducks_assert_duckdb_connection <- function(con) {
  if (!inherits(con, "duckdb_connection")) {
    stop("con must be a duckdb_connection", call. = FALSE)
  }
  invisible(TRUE)
}

rducks_validate_thread_count <- function(x, name) {
  if (is.null(x)) return(NULL)
  if (!is.numeric(x) || length(x) != 1L || is.na(x) || !is.finite(x) || x < 1 ||
      x != floor(x) || x > .Machine$integer.max) {
    stop(name, " must be a positive integer scalar or NULL", call. = FALSE)
  }
  as.integer(x)
}

rducks_configure_duckdb_threads <- function(con, threads = NULL, external_threads = NULL) {
  threads <- rducks_validate_thread_count(threads, "threads")
  external_threads <- rducks_validate_thread_count(external_threads, "external_threads")
  if (!is.null(threads) && !is.null(external_threads) && external_threads > threads) {
    stop("external_threads must be less than or equal to threads", call. = FALSE)
  }
  if (!is.null(threads)) {
    DBI::dbExecute(con, sprintf("PRAGMA threads=%d", threads))
  }
  if (!is.null(external_threads)) {
    DBI::dbExecute(con, sprintf("SET external_threads=%d", external_threads))
  }
  invisible(con)
}

rducks_restore_duckdb_threads <- function(con, threads, external_threads) {
  threads <- suppressWarnings(as.integer(threads))
  external_threads <- suppressWarnings(as.integer(external_threads))
  current_threads <- rducks_connection_threads(con)
  set_threads <- !is.na(threads) && threads >= 1L
  set_external <- !is.na(external_threads) && external_threads >= 1L
  if (set_external && set_threads && !is.na(current_threads) && threads < current_threads) {
    try(DBI::dbExecute(con, sprintf("SET external_threads=%d", external_threads)), silent = TRUE)
    try(DBI::dbExecute(con, sprintf("PRAGMA threads=%d", threads)), silent = TRUE)
  } else {
    if (set_threads) {
      try(DBI::dbExecute(con, sprintf("PRAGMA threads=%d", threads)), silent = TRUE)
    }
    if (set_external) {
      try(DBI::dbExecute(con, sprintf("SET external_threads=%d", external_threads)), silent = TRUE)
    }
  }
  invisible(con)
}

#' Set the Rducks execution plan for a connection
#'
#' Sets connection/session policy for Rducks chunk execution. Registration still
#' defines UDF semantics such as scalar versus vectorized call shape, declared
#' types, NULL handling, error handling, and side effects. The execution plan
#' chooses the marshalling implementation and concurrency contract.
#'
#' Compatibility note: the older `rducks_enable_inproc()` and
#' `rducks_disable_inproc()` helpers now set the `inproc_concurrent` and
#' `serial` concurrency parts of this plan while preserving the current
#' marshalling choice.
#'
#' @param con A `duckdb_connection` already enabled with [rducks_enable()].
#' @param plan An `rducks_execution_plan()` object.
#' @param threads Optional positive integer to set with `PRAGMA threads`.
#' @param external_threads Optional positive integer to set with
#'   `SET external_threads`. Use `NULL` to leave unchanged. For actual DuckDB
#'   worker concurrency, keep this smaller than `threads`.
#' @return `con`, invisibly.
#' @export
rducks_set_execution_plan <- function(con, plan = rducks_execution_plan(),
                                      threads = NULL, external_threads = NULL) {
  rducks_assert_duckdb_connection(con)
  plan <- rducks_as_execution_plan(plan)
  rducks_assert_execution_plan_implemented(plan)
  old_threads <- rducks_connection_threads(con)
  old_external_threads <- rducks_connection_external_threads(con)
  tryCatch(
    {
      rducks_configure_duckdb_threads(con, threads = threads, external_threads = external_threads)
      rducks_set_execution_backend(con, plan$backend)
    },
    error = function(e) {
      rducks_restore_duckdb_threads(con, old_threads, old_external_threads)
      stop(e)
    }
  )
  rducks_store_connection_plan(con, plan)
  invisible(con)
}

rducks_set_execution_backend <- function(con, backend) {
  ok <- DBI::dbGetQuery(
    con,
    sprintf("SELECT rducks_set_execution_backend(%s) AS ok", rducks_sql_string(backend))
  )$ok[[1L]]
  if (!isTRUE(ok)) {
    stop("failed to set Rducks execution backend to ", backend, call. = FALSE)
  }
  invisible(con)
}

rducks_connection_integer_setting <- function(con, setting) {
  query <- sprintf("SELECT current_setting(%s) AS value", rducks_sql_string(setting))
  value <- tryCatch(
    DBI::dbGetQuery(con, query)$value[[1L]],
    error = function(e) NA
  )
  suppressWarnings(as.integer(value))
}

rducks_connection_threads <- function(con) {
  rducks_connection_integer_setting(con, "threads")
}

rducks_connection_external_threads <- function(con) {
  rducks_connection_integer_setting(con, "external_threads")
}

rducks_runtime_token <- function(con, required = TRUE) {
  rducks_assert_duckdb_connection(con)
  token <- tryCatch(
    DBI::dbGetQuery(con, "SELECT rducks_runtime_token() AS token")$token[[1L]],
    error = function(e) NA_character_
  )
  if (is.na(token) && isTRUE(required)) {
    stop("Rducks is not enabled on this DuckDB connection", call. = FALSE)
  }
  token
}

rducks_assert_single_thread <- function(con) {
  threads <- rducks_connection_threads(con)
  external_threads <- rducks_connection_external_threads(con)
  if (!identical(threads, 1L) || !identical(external_threads, 1L)) {
    stop(
      "Rducks scalar UDFs require DuckDB to execute R code on the calling R thread; ",
      "call rducks_enable(con, threads = 'single') or set external_threads=1 and PRAGMA threads=1 ",
      "before registering R UDFs",
      call. = FALSE
    )
  }
  invisible(TRUE)
}
