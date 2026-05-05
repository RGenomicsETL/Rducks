rducks_registration_store <- function() {
  store <- .rducks_state$registrations
  if (is.null(store)) {
    store <- new.env(parent = emptyenv())
    .rducks_state$registrations <- store
  }
  store
}

rducks_connection_registration_store <- function(con, create = TRUE) {
  key <- rducks_connection_key(con)
  store <- rducks_registration_store()
  if (!exists(key, envir = store, inherits = FALSE)) {
    if (!create) return(NULL)
    assign(key, new.env(parent = emptyenv()), envir = store)
  }
  get(key, envir = store, inherits = FALSE)
}

rducks_store_registration <- function(registration) {
  env <- rducks_connection_registration_store(registration$connection, create = TRUE)
  record <- list(
    name = registration$spec$name,
    mode = registration$spec$mode,
    args = registration$spec$args,
    returns = registration$spec$returns,
    signature = registration$spec$signature,
    null_handling = registration$null_handling,
    exception_handling = registration$exception_handling,
    side_effects = registration$side_effects,
    execution_plan = registration$execution_plan
  )
  assign(registration$spec$name, record, envir = env)
  invisible(record)
}

rducks_get_registration_record <- function(con, name) {
  env <- rducks_connection_registration_store(con, create = FALSE)
  if (is.null(env) || !exists(name, envir = env, inherits = FALSE)) {
    return(NULL)
  }
  get(name, envir = env, inherits = FALSE)
}

rducks_native_udf_stat_fields <- c(
  "name",
  "eval_mode",
  "marshalling",
  "dispatch_chunks",
  "dispatch_rows",
  "direct_chunks",
  "queued_chunks",
  "queue_pending_current",
  "queue_pending_max",
  "arrow_r_chunks",
  "arrow_c_chunks",
  "arrow_ipc_chunks",
  "ripc_collect_batches",
  "ripc_collect_requests",
  "ripc_collect_max_batch",
  "ripc_submit_wave_max",
  "ripc_collect_ready_max",
  "duckdb_pending_tasks_executed",
  "ripc_inflight_current",
  "ripc_inflight_max"
)

rducks_native_udf_stats <- function(con, name) {
  values_sql <- paste(sprintf("(%s)", vapply(rducks_native_udf_stat_fields, rducks_sql_string, character(1))), collapse = ", ")
  sql <- sprintf(
    "SELECT field, rducks_udf_stat(%s, field) AS value FROM (VALUES %s) AS t(field)",
    rducks_sql_string(name),
    values_sql
  )
  res <- DBI::dbGetQuery(con, sql)
  stats <- stats::setNames(as.character(res$value), as.character(res$field))
  stats[rducks_native_udf_stat_fields]
}

rducks_counter_value <- function(stats, name) {
  value <- suppressWarnings(as.numeric(stats[[name]]))
  if (length(value) != 1L || is.na(value)) 0 else value
}

rducks_explain_udf_empty <- function() {
  data.frame(
    name = character(),
    mode = character(),
    plan_id = character(),
    marshalling = character(),
    concurrency = character(),
    native_marshalling = character(),
    evaluator = character(),
    args = character(),
    returns = character(),
    null_handling = character(),
    exception_handling = character(),
    side_effects = logical(),
    dispatch_chunks = numeric(),
    dispatch_rows = numeric(),
    direct_chunks = numeric(),
    queued_chunks = numeric(),
    queue_pending_current = numeric(),
    queue_pending_max = numeric(),
    arrow_r_chunks = numeric(),
    arrow_c_chunks = numeric(),
    arrow_ipc_chunks = numeric(),
    ripc_collect_batches = numeric(),
    ripc_collect_requests = numeric(),
    ripc_collect_max_batch = numeric(),
    ripc_submit_wave_max = numeric(),
    ripc_collect_ready_max = numeric(),
    duckdb_pending_tasks_executed = numeric(),
    ripc_inflight_current = numeric(),
    ripc_inflight_max = numeric(),
    stringsAsFactors = FALSE
  )
}

rducks_explain_udf_row <- function(con, name) {
  record <- rducks_get_registration_record(con, name)
  stats <- rducks_native_udf_stats(con, name)
  plan <- if (!is.null(record)) record$execution_plan else NULL

  data.frame(
    name = unname(stats[["name"]]),
    mode = if (!is.null(record)) record$mode else NA_character_,
    plan_id = if (!is.null(plan)) plan$plan_id else NA_character_,
    marshalling = if (!is.null(plan)) plan$marshalling else unname(stats[["marshalling"]]),
    concurrency = if (!is.null(plan)) plan$concurrency else NA_character_,
    native_marshalling = unname(stats[["marshalling"]]),
    evaluator = unname(stats[["eval_mode"]]),
    args = if (!is.null(record)) paste(record$args, collapse = ",") else NA_character_,
    returns = if (!is.null(record)) record$returns else NA_character_,
    null_handling = if (!is.null(record)) record$null_handling else NA_character_,
    exception_handling = if (!is.null(record)) record$exception_handling else NA_character_,
    side_effects = if (!is.null(record)) isTRUE(record$side_effects) else NA,
    dispatch_chunks = rducks_counter_value(stats, "dispatch_chunks"),
    dispatch_rows = rducks_counter_value(stats, "dispatch_rows"),
    direct_chunks = rducks_counter_value(stats, "direct_chunks"),
    queued_chunks = rducks_counter_value(stats, "queued_chunks"),
    queue_pending_current = rducks_counter_value(stats, "queue_pending_current"),
    queue_pending_max = rducks_counter_value(stats, "queue_pending_max"),
    arrow_r_chunks = rducks_counter_value(stats, "arrow_r_chunks"),
    arrow_c_chunks = rducks_counter_value(stats, "arrow_c_chunks"),
    arrow_ipc_chunks = rducks_counter_value(stats, "arrow_ipc_chunks"),
    ripc_collect_batches = rducks_counter_value(stats, "ripc_collect_batches"),
    ripc_collect_requests = rducks_counter_value(stats, "ripc_collect_requests"),
    ripc_collect_max_batch = rducks_counter_value(stats, "ripc_collect_max_batch"),
    ripc_submit_wave_max = rducks_counter_value(stats, "ripc_submit_wave_max"),
    ripc_collect_ready_max = rducks_counter_value(stats, "ripc_collect_ready_max"),
    duckdb_pending_tasks_executed = rducks_counter_value(stats, "duckdb_pending_tasks_executed"),
    ripc_inflight_current = rducks_counter_value(stats, "ripc_inflight_current"),
    ripc_inflight_max = rducks_counter_value(stats, "ripc_inflight_max"),
    stringsAsFactors = FALSE
  )
}

#' Explain a registered Rducks UDF
#'
#' Returns the R-side registration metadata together with native execution
#' counters for a UDF registered by [rducks_register()]. The native counters are
#' useful for checking that a plan executed through its requested evaluator
#' instead of silently falling back: for example, an `arrow_c` scalar UDF should
#' increment `arrow_c_chunks` and leave `arrow_r_chunks` unchanged.
#'
#' @param con A `duckdb_connection` with Rducks enabled.
#' @param name SQL function name registered with [rducks_register()].
#' @return A one-row data frame with registration metadata and native counters.
#' @export
rducks_explain_udf <- function(con, name) {
  rducks_assert_duckdb_connection(con)
  if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)) {
    stop("name must be a non-empty character scalar", call. = FALSE)
  }

  rducks_explain_udf_row(con, name)
}

#' List registered Rducks UDFs
#'
#' Returns one row per UDF registered through [rducks_register()] on a
#' connection, including the same registration metadata and native counters as
#' [rducks_explain_udf()]. This is an Rducks registry view, not a complete DuckDB
#' catalog listing: functions registered by other extensions or raw SQL are not
#' included.
#'
#' @param con A `duckdb_connection` with Rducks enabled.
#' @return A data frame with one row per Rducks UDF registered on `con`.
#' @export
rducks_list_udfs <- function(con) {
  rducks_assert_duckdb_connection(con)
  env <- rducks_connection_registration_store(con, create = FALSE)
  if (is.null(env)) {
    return(rducks_explain_udf_empty())
  }
  names <- sort(ls(envir = env, all.names = TRUE))
  if (!length(names)) {
    return(rducks_explain_udf_empty())
  }
  rows <- lapply(names, function(name) rducks_explain_udf_row(con, name))
  do.call(rbind, rows)
}
