rducks_registration_store <- function() {
  rducks_get_or_init_store("registrations")
}

rducks_database_registration_key <- function(con, required = TRUE) {
  rducks_runtime_token(con, required = required)
}

rducks_database_registration_store <- function(con, create = TRUE) {
  key <- if (isTRUE(create)) {
    rducks_database_registration_key(con, required = TRUE)
  } else {
    rducks_attached_runtime_token(con)
  }
  if (is.na(key)) return(NULL)
  store <- rducks_registration_store()
  if (!exists(key, envir = store, inherits = FALSE)) {
    if (!create) return(NULL)
    assign(key, new.env(parent = emptyenv()), envir = store)
  }
  get(key, envir = store, inherits = FALSE)
}

rducks_store_registration <- function(registration) {
  env <- rducks_database_registration_store(registration$connection, create = TRUE)
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
  env <- rducks_database_registration_store(con, create = FALSE)
  if (is.null(env) || !exists(name, envir = env, inherits = FALSE)) {
    return(NULL)
  }
  get(name, envir = env, inherits = FALSE)
}

# Compatibility field list used only when the optional native discovery helper
# is unavailable, e.g. because a user-defined SQL name collision prevented its
# registration. When the helper exists, R trusts the native field list.
rducks_native_udf_stat_fields_compat <- c(
  "name",
  "eval_mode",
  "marshalling",
  "dispatch_chunks",
  "dispatch_rows",
  "direct_chunks",
  "queued_chunks",
  "queue_pending_current",
  "queue_pending_max",
  "sexp_chunks",
  "direct_eval_chunks",
  "direct_input_snapshot_chunks",
  "direct_owned_result_chunk_chunks",
  "wire_chunks",
  "ripc_collect_batches",
  "ripc_collect_requests",
  "ripc_collect_max_batch",
  "ripc_submit_wave_max",
  "ripc_collect_ready_max",
  "ripc_inflight_current",
  "ripc_inflight_max"
)

rducks_native_udf_stat_fields <- function(con) {
  fields <- tryCatch({
    raw <- DBI::dbGetQuery(con, "SELECT rducks_udf_stat_fields() AS fields")$fields[[1L]]
    strsplit(raw, "\n", fixed = TRUE)[[1L]]
  }, error = function(e) rducks_native_udf_stat_fields_compat)
  fields <- fields[nzchar(fields)]
  if (length(fields)) fields else rducks_native_udf_stat_fields_compat
}

rducks_native_udf_stats <- function(con, name) {
  fields <- rducks_native_udf_stat_fields(con)
  values_sql <- paste(sprintf("(%s)", vapply(fields, rducks_sql_string, character(1))), collapse = ", ")
  sql <- sprintf(
    "SELECT field, rducks_udf_stat(%s, field) AS value FROM (VALUES %s) AS t(field)",
    rducks_sql_string(name),
    values_sql
  )
  res <- DBI::dbGetQuery(con, sql)
  stats <- stats::setNames(as.character(res$value), as.character(res$field))
  stats[fields]
}

rducks_counter_value <- function(stats, name) {
  value <- suppressWarnings(as.numeric(stats[[name]]))
  if (length(value) != 1L || is.na(value)) 0 else value
}

rducks_explain_udf_columns <- list(
  name = character,
  mode = character,
  plan_id = character,
  engine_id = character,
  marshalling = character,
  concurrency = character,
  native_marshalling = character,
  evaluator = character,
  args = character,
  returns = character,
  r_side_record = logical,
  null_handling = character,
  exception_handling = character,
  side_effects = logical,
  dispatch_chunks = numeric,
  dispatch_rows = numeric,
  direct_chunks = numeric,
  queued_chunks = numeric,
  queue_pending_current = numeric,
  queue_pending_max = numeric,
  sexp_chunks = numeric,
  direct_eval_chunks = numeric,
  direct_input_snapshot_chunks = numeric,
  direct_owned_result_chunk_chunks = numeric,
  wire_chunks = numeric,
  ripc_collect_batches = numeric,
  ripc_collect_requests = numeric,
  ripc_collect_max_batch = numeric,
  ripc_submit_wave_max = numeric,
  ripc_collect_ready_max = numeric,
  ripc_inflight_current = numeric,
  ripc_inflight_max = numeric
)

rducks_explain_udf_frame <- function(values = NULL) {
  if (is.null(values)) {
    values <- lapply(rducks_explain_udf_columns, function(factory) factory())
  } else {
    missing <- setdiff(names(rducks_explain_udf_columns), names(values))
    extra <- setdiff(names(values), names(rducks_explain_udf_columns))
    if (length(missing) || length(extra)) {
      stop("Rducks explain UDF schema mismatch", call. = FALSE)
    }
    values <- values[names(rducks_explain_udf_columns)]
  }
  data.frame(values, stringsAsFactors = FALSE)
}

rducks_explain_udf_empty <- function() {
  rducks_explain_udf_frame()
}

rducks_explain_udf_row <- function(con, name) {
  record <- rducks_get_registration_record(con, name)
  stats <- rducks_native_udf_stats(con, name)
  plan <- if (!is.null(record)) record$execution_plan else NULL

  rducks_explain_udf_frame(list(
    name = unname(stats[["name"]]),
    mode = if (!is.null(record)) record$mode else NA_character_,
    plan_id = if (!is.null(plan)) plan$plan_id else NA_character_,
    engine_id = if (!is.null(plan)) plan$engine_id %||% NA_character_ else NA_character_,
    marshalling = if (!is.null(plan)) plan$marshalling else unname(stats[["marshalling"]]),
    concurrency = if (!is.null(plan)) plan$concurrency else NA_character_,
    native_marshalling = unname(stats[["marshalling"]]),
    evaluator = unname(stats[["eval_mode"]]),
    args = if (!is.null(record)) paste(record$args, collapse = ",") else NA_character_,
    returns = if (!is.null(record)) record$returns else NA_character_,
    r_side_record = !is.null(record),
    null_handling = if (!is.null(record)) record$null_handling else NA_character_,
    exception_handling = if (!is.null(record)) record$exception_handling else NA_character_,
    side_effects = if (!is.null(record)) isTRUE(record$side_effects) else NA,
    dispatch_chunks = rducks_counter_value(stats, "dispatch_chunks"),
    dispatch_rows = rducks_counter_value(stats, "dispatch_rows"),
    direct_chunks = rducks_counter_value(stats, "direct_chunks"),
    queued_chunks = rducks_counter_value(stats, "queued_chunks"),
    queue_pending_current = rducks_counter_value(stats, "queue_pending_current"),
    queue_pending_max = rducks_counter_value(stats, "queue_pending_max"),
    sexp_chunks = rducks_counter_value(stats, "sexp_chunks"),
    direct_eval_chunks = rducks_counter_value(stats, "direct_eval_chunks"),
    direct_input_snapshot_chunks = rducks_counter_value(stats, "direct_input_snapshot_chunks"),
    direct_owned_result_chunk_chunks = rducks_counter_value(stats, "direct_owned_result_chunk_chunks"),
    wire_chunks = rducks_counter_value(stats, "wire_chunks"),
    ripc_collect_batches = rducks_counter_value(stats, "ripc_collect_batches"),
    ripc_collect_requests = rducks_counter_value(stats, "ripc_collect_requests"),
    ripc_collect_max_batch = rducks_counter_value(stats, "ripc_collect_max_batch"),
    ripc_submit_wave_max = rducks_counter_value(stats, "ripc_submit_wave_max"),
    ripc_collect_ready_max = rducks_counter_value(stats, "ripc_collect_ready_max"),
    ripc_inflight_current = rducks_counter_value(stats, "ripc_inflight_current"),
    ripc_inflight_max = rducks_counter_value(stats, "ripc_inflight_max")
  ))
}

#' Explain a registered Rducks scalar UDF
#'
#' Returns the R-side registration metadata together with native execution
#' counters for a DuckDB scalar UDF registered by
#' \code{\link[=rducks_register_scalar_udf]{rducks_register_scalar_udf()}}. The
#' `mode` column is the Rducks scalar-UDF evaluation mode, while `plan_id`,
#' `marshalling`, and `concurrency` describe the plan recorded at registration
#' time. The
#' `r_side_record` column is `FALSE` when native catalog metadata is still
#' present but the connection-local R registry view was detached or is otherwise
#' unavailable. The native counters are useful for checking that a plan executed
#' through its requested evaluator instead of silently switching engines: for
#' example, a direct scalar UDF should increment `direct_eval_chunks` and leave
#' `wire_chunks` unchanged.
#'
#' @param con A `duckdb_connection` with Rducks enabled.
#' @param name SQL scalar-UDF function name registered with
#'   \code{\link[=rducks_register_scalar_udf]{rducks_register_scalar_udf()}}.
#' @return A one-row data frame with scalar-UDF registration metadata and native counters.
#' @examples
#' \donttest{
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db, threads = "single")
#' rducks_register_scalar_udf(db, "my_fn", function(x) x + 1L,
#'   args = list(INTEGER), returns = INTEGER)
#' rducks_explain_udf(db, "my_fn")
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
#' @export
rducks_explain_udf <- function(con, name) {
  rducks_assert_duckdb_connection(con)
  rducks_assert_non_empty_character_scalar(name, "name")

  rducks_explain_udf_row(con, name)
}

#' Reset Rducks scalar-UDF counters
#'
#' Resets native per-scalar-UDF diagnostic counters without unregistering any
#' DuckDB catalog function. Current liveness gauges such as pending/in-flight
#' counts are preserved; their max fields are reset to the current values.
#'
#' @param con A `duckdb_connection` with Rducks enabled.
#' @param name Optional SQL scalar-UDF function name registered with
#'   \code{\link[=rducks_register_scalar_udf]{rducks_register_scalar_udf()}}. If
#'   `NULL`, reset counters for all native Rducks scalar UDFs in the database runtime.
#' @return Invisibly `TRUE` on success.
#' @examples
#' \donttest{
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db, threads = "single")
#' rducks_register_scalar_udf(db, "my_fn", function(x) x + 1L,
#'   args = list(INTEGER), returns = INTEGER)
#' rducks_reset_udf_counters(db, "my_fn")
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
#' @export
rducks_reset_udf_counters <- function(con, name = NULL) {
  rducks_assert_duckdb_connection(con)
  if (is.null(name)) {
    name <- ""
  } else if (!rducks_is_non_empty_character_scalar(name)) {
    stop("name must be NULL or a non-empty character scalar", call. = FALSE)
  }
  ok <- DBI::dbGetQuery(
    con,
    sprintf("SELECT rducks_reset_udf_stats(%s) AS ok", rducks_sql_string(name))
  )$ok[[1L]]
  if (!isTRUE(ok)) stop("failed to reset Rducks UDF counters", call. = FALSE)
  invisible(TRUE)
}

#' List registered Rducks scalar UDFs
#'
#' Returns one row per DuckDB scalar UDF registered through
#' \code{\link[=rducks_register_scalar_udf]{rducks_register_scalar_udf()}} in
#' the current DuckDB database runtime, including the same registration metadata
#' and native counters as \code{\link[=rducks_explain_udf]{rducks_explain_udf()}}.
#' This is an Rducks scalar-UDF registry view, not a complete DuckDB catalog
#' listing: aggregate functions, table functions, functions registered by other
#' extensions, and raw SQL functions are not included. Because DuckDB's function
#' catalog is database scoped, sibling DBI connections to the same database
#' runtime share this view.
#'
#' @param con A `duckdb_connection` with Rducks enabled.
#' @return A data frame with one row per Rducks scalar UDF registered on `con`.
#' @examples
#' \donttest{
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db, threads = "single")
#' rducks_register_scalar_udf(db, "my_fn", function(x) x + 1L,
#'   args = list(INTEGER), returns = INTEGER)
#' rducks_list_udfs(db)
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
#' @export
rducks_list_udfs <- function(con) {
  rducks_assert_duckdb_connection(con)
  env <- rducks_database_registration_store(con, create = FALSE)
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
