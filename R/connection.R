#' Locate the built Rducks DuckDB extension
#'
#' @return Character scalar path to `rducks.duckdb_extension`.
#' @examples
#' rducks_extension_path()
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
#' explicitly. Use \code{\link[=rducks_set_execution_plan]{rducks_set_execution_plan()}}
#' before scalar-UDF registration to select direct serial or queued in-process
#' execution.
#'
#' @param con A `duckdb_connection`.
#' @param extension_path Extension path. Defaults to \code{\link[=rducks_extension_path]{rducks_extension_path()}}.
#' @param threads Either `"unchanged"` or `"single"`.
#' @return `con`, invisibly.
#' @examples
#' \donttest{
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db)
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
#' @export
rducks_enable <- function(con, extension_path = rducks_extension_path(),
                          threads = c("unchanged", "single")) {
  threads <- match.arg(threads)
  rducks_assert_duckdb_connection(con)

  path_sql <- rducks_sql_string(normalizePath(extension_path, mustWork = TRUE))
  DBI::dbExecute(con, sprintf("LOAD %s", path_sql))

  # Record whether this DuckDB build + extension can carry VARIANT end-to-end;
  # the type gates consult the cached value.
  rducks_cache_variant_runtime_support(con)

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
  rducks_set_execution_plan(con, rducks_execution_plan_internal("direct", "serial"))
  invisible(con)
}

rducks_set_inproc_state <- function(con, concurrency, threads = NULL, external_threads = NULL) {
  rducks_assert_duckdb_connection(con)
  current <- rducks_current_execution_plan(con)
  plan <- rducks_execution_plan_internal(current$marshalling, concurrency)
  rducks_set_execution_plan(con, plan, threads = threads, external_threads = external_threads)
  invisible(con)
}

#' Enable in-process queued scalar-UDF execution
#'
#' Switches a Rducks-enabled DuckDB connection to an `inproc_concurrent`
#' execution plan for subsequent scalar-UDF registrations and updates the native
#' runtime backend. This backend preserves R's thread discipline: DuckDB
#' worker-side scalar-UDF callbacks submit chunk requests to an extension-owned
#' queue, and the recorded main R thread drains the queue and performs all R API
#' work. This is a same-process scheduling mode, not a performance promise; R
#' function calls are still serialized on the main R thread.
#'
#' This is a helper for the direct in-process queue. New code can call
#' \code{\link[=rducks_set_execution_plan]{rducks_set_execution_plan()}}
#' directly with `rducks_execution_plan("inproc")`. Select the plan
#' before registering scalar UDFs whose reported execution plan should be the
#' queued in-process path.
#'
#' @param con A `duckdb_connection` already enabled with \code{\link[=rducks_enable]{rducks_enable()}}.
#' @param threads Optional positive integer to set with `PRAGMA threads` before
#'   enabling the in-process backend. Use `NULL` to leave unchanged.
#' @param external_threads Optional positive integer to set with
#'   `SET external_threads` before enabling the in-process backend. Use `NULL`
#'   to leave unchanged. For actual DuckDB worker concurrency, keep this smaller
#'   than `threads` (for example `threads = 4, external_threads = 1`).
#' @return `con`, invisibly.
#' @examples
#' \donttest{
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db)
#' rducks_enable_inproc(db)
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
#' @export
rducks_enable_inproc <- function(con, threads = NULL, external_threads = NULL) {
  rducks_set_inproc_state(con, "inproc_concurrent", threads = threads, external_threads = external_threads)
}

#' Disable in-process queued scalar-UDF execution
#'
#' Switches a Rducks-enabled DuckDB connection back to the direct serial backend.
#' Optionally updates DuckDB thread settings at the same time.
#'
#' @param con A `duckdb_connection`.
#' @param threads Optional positive integer to set with `PRAGMA threads`.
#' @param external_threads Optional positive integer to set with
#'   `SET external_threads`. Use `NULL` to leave unchanged.
#' @return `con`, invisibly.
#' @examples
#' \donttest{
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db)
#' rducks_enable_inproc(db)
#' rducks_disable_inproc(db)
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
#' @export
rducks_disable_inproc <- function(con, threads = NULL, external_threads = NULL) {
  rducks_set_inproc_state(con, "serial", threads = threads, external_threads = external_threads)
}

#' Detach Rducks connection-local state
#'
#' Detaches Rducks' connection-local R state for `con`. This clears the current
#' default execution plan and releases this connection's R-side runtime anchor.
#' It does not drop DuckDB catalog functions, unregister scalar UDFs, or release
#' native-owned R closures that are still referenced by database-scoped catalog
#' metadata. If sibling DBI connections are attached to the same DuckDB database
#' runtime, their database-scoped Rducks registration metadata remains visible.
#' For file-backed databases, releasing the
#' last attachment also closes Rducks' extension-owned DuckDB connections, which
#' lets the DuckDB file be closed and reopened in the same R process on
#' platforms with strict file locking.
#'
#' Rducks deliberately keeps the plain `duckdb_connection` object and does not
#' override DBI's `dbDisconnect()` method. Call `rducks_release(con)` explicitly
#' before `DBI::dbDisconnect(con)` when you want deterministic connection-local
#' Rducks cleanup; weak-reference finalizers provide only best-effort cleanup if
#' the connection object is garbage-collected.
#'
#' Call \code{\link[=rducks_enable]{rducks_enable()}} again before using `con` for further Rducks
#' registrations or connection-local plan changes.
#'
#' @param con A `duckdb_connection`.
#' @return `con`, invisibly.
#' @examples
#' \donttest{
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db)
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
#' @export
rducks_release <- function(con) {
  rducks_assert_duckdb_connection(con)
  token <- rducks_existing_connection_token(con)
  db_token <- rducks_attached_runtime_token(con)
  last_runtime_anchor <- FALSE
  if (!is.na(token) && !is.na(db_token)) {
    anchor_store <- .rducks_state$runtime_anchors
    if (!is.null(anchor_store) && exists(db_token, envir = anchor_store, inherits = FALSE)) {
      anchor_env <- get(db_token, envir = anchor_store, inherits = FALSE)
      anchors <- ls(envir = anchor_env, all.names = TRUE)
      last_runtime_anchor <- identical(sort(anchors), token)
    }
  }
  # If the extension is still reachable, give native code a safe recorded-main-
  # thread drain point for preserved R objects queued by off-main DuckDB catalog
  # destructors. This is non-destructive: it does not drop functions or release
  # closures still owned by live catalog metadata.
  try(rducks_runtime_token(con, required = FALSE), silent = TRUE)
  if (isTRUE(last_runtime_anchor)) {
    try(DBI::dbGetQuery(con, "SELECT rducks_nng_quiesce() AS ok"), silent = TRUE)
  }
  rducks_detach_connection_token(con)
  if (isTRUE(last_runtime_anchor) && rducks_connection_is_file_backed(con)) {
    try(DBI::dbGetQuery(con, "SELECT rducks_runtime_release_connections() AS ok"), silent = TRUE)
  }
  invisible(con)
}

rducks_connection_dbdir <- function(con) {
  tryCatch(methods::slot(methods::slot(con, "driver"), "dbdir"), error = function(e) NA_character_)
}

rducks_connection_is_file_backed <- function(con) {
  dbdir <- rducks_connection_dbdir(con)
  is.character(dbdir) && length(dbdir) == 1L && !is.na(dbdir) && nzchar(dbdir) &&
    !identical(dbdir, ":memory:")
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
#' `main_drains`, `main_drain_batches`, and `main_drain_max_batch` count how
#' often the recorded main R thread attempted queue drains and how many queued
#' requests were handled in non-empty drain waves. `pending_timeout_ms` is the
#' configured native pending-request timeout. Running requests borrow DuckDB
#' callback-frame input/output storage, so running-timeout cancellation is
#' intentionally not supported and is reported via
#' `running_timeout_supported = FALSE`. This is a runtime queue summary; for
#' per-scalar-UDF execution detail such as selected evaluator and direct
#' input/result counters, use
#' \code{\link[=rducks_explain_udf]{rducks_explain_udf()}}.
#'
#' @param con A `duckdb_connection`.
#' @return A one-row data frame with queue diagnostic columns.
#' @examples
#' \donttest{
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db)
#' rducks_inproc_stats(db)
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
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
      "rducks_queue_main_drains() AS main_drains,",
      "rducks_queue_main_drain_batches() AS main_drain_batches,",
      "rducks_queue_main_drain_max_batch() AS main_drain_max_batch,",
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
#' \code{\link[=rducks_enable]{rducks_enable()}}, \code{\link[=rducks_release]{rducks_release()}},
#' \code{\link[=rducks_register_scalar_udf]{rducks_register_scalar_udf()}},
#' scalar-UDF execution, and metadata/stat queries.
#'
#' @param con A `duckdb_connection`.
#' @return A one-row data frame with queued, released, failed, and pending
#'   counters.
#' @examples
#' \donttest{
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db)
#' rducks_release_stats(db)
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
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
#' `connections_current` and `native_release_supported` are derived R-side
#' summary fields. For file-backed databases, Rducks closes extension-owned
#' DuckDB connections when the last Rducks attachment to a runtime is released;
#' the process-local runtime entry itself is retained as inert metadata so
#' catalog destructors and stale database-address detection remain safe.
#'
#' @param con An enabled `duckdb_connection`.
#' @return A one-row data frame with runtime registry and connection counters.
#' @examples
#' \donttest{
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db)
#' rducks_runtime_stats(db)
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
#' @export
rducks_runtime_stats <- function(con) {
  rducks_assert_duckdb_connection(con)
  stats <- DBI::dbGetQuery(
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
  stats$connections_current <- stats$connections_opened - stats$connections_closed
  stats$native_release_supported <- rep(TRUE, nrow(stats))
  stats[, c(
    "registry_entries", "active_entries", "stale_entries", "entries_created",
    "stale_aliases", "connections_opened", "connections_closed",
    "connections_current", "connection_open_failed", "queue_init_failed",
    "native_release_supported"
  )]
}

#' Exercise the in-process queue
#'
#' Runs a native self-test that submits `n` requests from worker threads to the
#' extension-owned main-thread queue and drains them on the recorded main R
#' thread. This validates the queue/condition-variable path without calling an R
#' UDF. This diagnostic SQL surface is dev/test-only; set
#' `RDUCKS_DEV_SURFACES=true` before `rducks_enable()` if you need it.
#'
#' @param con A `duckdb_connection`.
#' @param n Number of queue round trips to run.
#' @return Integer-like numeric scalar: number of requests completed.
#' @examples
#' \dontrun{
#' # Requires RDUCKS_DEV_SURFACES=true set before rducks_enable()
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db)
#' rducks_inproc_self_test(db, n = 10L)
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
#' @export
rducks_inproc_self_test <- function(con, n = 1000L) {
  rducks_assert_duckdb_connection(con)
  if (!rducks_dev_surfaces_enabled()) {
    stop(
      "rducks_inproc_self_test() requires RDUCKS_DEV_SURFACES=true before rducks_enable()",
      call. = FALSE
    )
  }
  n <- rducks_validate_thread_count(n, "n")
  DBI::dbGetQuery(
    con,
    sprintf("SELECT rducks_queue_self_test(%s::UBIGINT) AS n", as.character(n))
  )$n[[1L]]
}

rducks_inproc_cancel_self_test <- function(con, n = 1000L, cancel_after = 1L) {
  rducks_assert_duckdb_connection(con)
  if (!rducks_dev_surfaces_enabled()) {
    stop(
      "rducks_inproc_cancel_self_test() requires RDUCKS_DEV_SURFACES=true before rducks_enable()",
      call. = FALSE
    )
  }
  n <- rducks_validate_thread_count(n, "n")
  cancel_after <- rducks_validate_nonnegative_count(cancel_after, "cancel_after")
  DBI::dbGetQuery(
    con,
    sprintf(
      "SELECT rducks_queue_self_test_cancel(%s::UBIGINT, %s::UBIGINT) AS n",
      as.character(n),
      as.character(cancel_after)
    )
  )$n[[1L]]
}

rducks_dev_surfaces_enabled <- function() {
  tolower(Sys.getenv("RDUCKS_DEV_SURFACES", "")) %in% c("1", "true", "yes", "on")
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

rducks_validate_nonnegative_count <- function(x, name) {
  if (!is.numeric(x) || length(x) != 1L || is.na(x) || !is.finite(x) || x < 0 ||
      x != floor(x) || x > .Machine$integer.max) {
    stop(name, " must be a non-negative integer scalar", call. = FALSE)
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

rducks_force_single_thread_sql <- function(con) {
  DBI::dbExecute(con, "SET external_threads=1")
  DBI::dbExecute(con, "PRAGMA threads=1")
  invisible(con)
}

rducks_thread_setting_or_null <- function(x) {
  x <- suppressWarnings(as.integer(x))
  if (length(x) != 1L || is.na(x) || x < 1L) NULL else x
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
#' Stores the R-side default execution plan used by subsequent
#' \code{\link[=rducks_register_scalar_udf]{rducks_register_scalar_udf()}} calls
#' through this connection and updates the native runtime backend needed by that
#' plan. Scalar-UDF registration still defines Rducks evaluation semantics such
#' as scalar row calls versus vectorized chunk calls, declared types, NULL
#' handling, error handling, and side effects. The selected evaluator/marshalling
#' for an already-registered scalar UDF remains frozen in its database-catalog
#' metadata.
#'
#' @param con A `duckdb_connection` already enabled with \code{\link[=rducks_enable]{rducks_enable()}}.
#' @param plan An `rducks_execution_plan()` object.
#' @param threads Optional positive integer to set with `PRAGMA threads`.
#' @param external_threads Optional positive integer to set with
#'   `SET external_threads`. Use `NULL` to restore/keep the previous setting
#'   after Rducks briefly forces single-thread SQL execution to update its native
#'   backend on the recorded main R thread. For actual DuckDB worker
#'   concurrency, keep this smaller than `threads`.
#' @return `con`, invisibly.
#' @examples
#' \donttest{
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db)
#' rducks_set_execution_plan(db, rducks_execution_plan("inproc"))
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
#' @export
rducks_set_execution_plan <- function(con, plan = rducks_execution_plan(),
                                      threads = NULL, external_threads = NULL) {
  rducks_assert_duckdb_connection(con)
  plan <- rducks_as_execution_plan(plan)
  rducks_assert_execution_plan_implemented(plan)
  threads <- rducks_validate_thread_count(threads, "threads")
  external_threads <- rducks_validate_thread_count(external_threads, "external_threads")
  old_threads <- rducks_connection_threads(con)
  old_external_threads <- rducks_connection_external_threads(con)
  old_backend <- tryCatch(rducks_native_execution_backend(con), error = function(e) NULL)
  target_threads <- threads %||% rducks_thread_setting_or_null(old_threads)
  target_external_threads <- external_threads %||% rducks_thread_setting_or_null(old_external_threads)
  if (!is.null(target_threads) && !is.null(target_external_threads) && target_external_threads > target_threads) {
    stop("external_threads must be less than or equal to threads", call. = FALSE)
  }
  tryCatch(
    {
      rducks_force_single_thread_sql(con)
      rducks_set_execution_backend(con, plan$backend)
      rducks_configure_duckdb_threads(
        con,
        threads = target_threads,
        external_threads = target_external_threads
      )
    },
    error = function(e) {
      try(rducks_force_single_thread_sql(con), silent = TRUE)
      if (!is.null(old_backend)) {
        try(rducks_set_execution_backend(con, old_backend), silent = TRUE)
      }
      rducks_restore_duckdb_threads(con, old_threads, old_external_threads)
      stop(e)
    }
  )
  rducks_store_connection_plan(con, plan)
  invisible(con)
}

#' Inspect the native Rducks execution backend
#'
#' Returns the backend currently recorded in the native database-scoped runtime.
#' This is a diagnostic cross-check for \code{\link[=rducks_current_execution_plan]{rducks_current_execution_plan()}}, whose
#' value is the R-side default plan for future registrations through this
#' connection.
#'
#' @param con A `duckdb_connection` already enabled with \code{\link[=rducks_enable]{rducks_enable()}}.
#' @return Character scalar backend name: `"single"`, `"concurrent_inproc"`,
#'   or `"multiprocess_parallel"`.
#' @examples
#' \donttest{
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db)
#' rducks_native_execution_backend(db)
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
#' @export
rducks_native_execution_backend <- function(con) {
  rducks_assert_duckdb_connection(con)
  DBI::dbGetQuery(con, "SELECT rducks_execution_backend() AS backend")$backend[[1L]]
}

rducks_set_execution_backend <- function(con, backend) {
  payload <- paste(rducks_main_thread_token(), backend, sep = "\n")
  ok <- DBI::dbGetQuery(
    con,
    sprintf("SELECT rducks_set_execution_backend(%s) AS ok", rducks_sql_string(payload))
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
      "Rducks R-backed functions require DuckDB to execute R code on the calling R thread; ",
      "call rducks_enable(con, threads = 'single') or set external_threads=1 and PRAGMA threads=1 ",
      "before registering R-backed functions",
      call. = FALSE
    )
  }
  invisible(TRUE)
}
