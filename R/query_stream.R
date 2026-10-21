rducks_query_stream_batch_store <- function() {
  rducks_get_or_init_store("query_stream_batches")
}

# Called from the extension (C) on the recorded R thread with the materialized
# columns for one streamed DuckDB chunk. Stores them keyed by native token so
# the R-side `next_batch()` can retrieve the data frame after the native fetch.
rducks_query_stream_store_native_batch <- function(token, columns, n) {
  assign(token, list(columns = columns, n = as.integer(n)), envir = rducks_query_stream_batch_store())
  invisible(NULL)
}

rducks_query_stream_take_native_batch <- function(token) {
  store <- rducks_query_stream_batch_store()
  if (!exists(token, envir = store, inherits = FALSE)) {
    return(NULL)
  }
  batch <- get(token, envir = store, inherits = FALSE)
  rm(list = token, envir = store)
  batch
}

rducks_query_stream_parse_metadata <- function(metadata) {
  if (!length(metadata) || is.na(metadata) || !nzchar(metadata)) {
    return(list(names = character(), types = character()))
  }
  lines <- strsplit(metadata, "\n", fixed = TRUE)[[1L]]
  lines <- lines[nzchar(lines)]
  if (!length(lines)) {
    return(list(names = character(), types = character()))
  }
  parts <- strsplit(lines, "\t", fixed = TRUE)
  list(
    names = vapply(parts, function(p) p[[1L]], character(1)),
    types = vapply(parts, function(p) if (length(p) >= 2L) p[[2L]] else "", character(1))
  )
}

# The finalizer must not close over the stream-creation frame: that frame owns
# the state environment and would otherwise retain the object being finalized.
rducks_query_stream_finalize <- function(state) {
  if (!isTRUE(state$closed)) {
    try(.Call(RDUCKS_query_stream_call, state$runtime_token, "close", state$token), silent = TRUE)
    state$closed <- TRUE
    rducks_query_stream_take_native_batch(state$token)
  }
  invisible(NULL)
}

rducks_query_stream_driver_available <- function(con) {
  token <- rducks_attached_runtime_token(con)
  !is.na(token) && isTRUE(.Call(RDUCKS_query_stream_call, token, "driver_supported", ""))
}

#' Stream a DuckDB query as native data-frame batches
#'
#' Opens a native DuckDB streaming result through the Rducks extension and
#' returns the rows in DuckDB-sized batches as data frames, instead of an eager
#' `DBI::dbGetQuery()` result. Each batch is materialized directly from DuckDB
#' vectors to R values on the recorded R thread. The stream uses the extension's
#' database-scoped connection, so
#' it cannot see caller-connection temporary tables or views, uncommitted
#' transactions, or connection-local settings.
#'
#' With `rducks_execution_plan("inproc")`, one persistent native driver prepares,
#' executes, fetches, and closes the query while the recorded R thread services
#' scalar callbacks. Requests keep their original task identity and result
#' destination; no source-row ordering is promised. R table and aggregate
#' callbacks are unsupported in this managed mode and fail before off-thread R
#' access. This mode requires a duckdb-r build exposing version 1 of its
#' off-main R-source guard capability; ordinary builds without that capability
#' fail with an explicit error. Serial and IPC plans retain their synchronous
#' execution paths.
#' Only one stream can be open for a database runtime at a time. Recursive
#' stream operations, release, and plan changes during callbacks are rejected.
#'
#' @param con A `duckdb_connection` with Rducks enabled.
#' @param sql A non-empty SQL query string.
#' @return An object of class `rducks_query_stream` with `$next_batch()`
#'   (returns the next data-frame batch, or `NULL` at end of stream),
#'   `$close()`, `$schema` (column names and Rducks type tokens), and `$token`.
#'   The stream closes at end of input, on `$close()`, on native query error, when its handle
#'   is garbage-collected, or when `rducks_release()` drops the last runtime
#'   anchor. Explicit `$close()` releases resources promptly after early exit.
#' @examples
#' \donttest{
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db, threads = "single")
#' stream <- rducks_query_stream(db, "SELECT i::INTEGER AS i FROM range(1, 6) t(i)")
#' stream$next_batch()
#' stream$close()
#' rducks_release(db)
#' DBI::dbDisconnect(db, shutdown = TRUE)
#' }
#' @export
rducks_query_stream <- function(con, sql) {
  rducks_assert_duckdb_connection(con)
  if (!is.character(sql) || length(sql) != 1L || is.na(sql) || !nzchar(sql)) {
    stop("sql must be a non-empty character scalar", call. = FALSE)
  }
  runtime_token <- rducks_attached_runtime_token(con)
  if (is.na(runtime_token)) {
    stop("rducks_query_stream() requires rducks_enable(con) first", call. = FALSE)
  }
  managed <- identical(rducks_native_execution_backend(con), "concurrent_inproc")
  invoke <- function(operation, argument) {
    if (managed) {
      .Call(RDUCKS_query_stream_call, runtime_token, operation, argument)
    } else {
      # Synchronous plans keep duckdb-r's existing SQL interrupt boundary.
      DBI::dbGetQuery(con, sprintf(
        "SELECT rducks_query_stream_%s(%s) AS value", operation, rducks_sql_string(argument)
      ))[[1L]][[1L]]
    }
  }
  token <- NULL
  ready <- FALSE
  on.exit({
    if (!ready && !is.null(token)) {
      try(.Call(RDUCKS_query_stream_call, runtime_token, "close", token), silent = TRUE)
    }
  }, add = TRUE)
  # Managed streams enter directly from R, outside duckdb-r's SQL execution
  # interrupt handler, so the R pump can cancel the helper connection itself.
  token <- invoke("open", sql)
  metadata <- invoke("metadata", token)
  schema <- rducks_query_stream_parse_metadata(metadata)
  state <- new.env(parent = emptyenv())
  state$con <- con
  state$runtime_token <- runtime_token
  state$token <- token
  state$closed <- FALSE
  reg.finalizer(state, rducks_query_stream_finalize, onexit = TRUE)

  finalize_batch <- function(batch) {
    cols <- batch$columns
    if (length(schema$names) == length(cols)) names(cols) <- schema$names
    structure(cols, class = "data.frame", row.names = .set_row_names(batch$n))
  }
  close <- function() {
    if (isTRUE(state$closed)) return(invisible(NULL))
    invoke("close", state$token)
    # Keep the handle usable if native code rejects a recursive close.
    state$closed <- TRUE
    rducks_query_stream_take_native_batch(state$token)
    invisible(NULL)
  }
  next_batch <- function() {
    if (isTRUE(state$closed)) return(NULL)
    has_batch <- invoke("next", state$token)
    if (!isTRUE(has_batch)) {
      close()
      return(NULL)
    }
    batch <- rducks_query_stream_take_native_batch(state$token)
    if (is.null(batch)) stop("Rducks query stream returned no native batch", call. = FALSE)
    finalize_batch(batch)
  }
  stream <- structure(
    list(next_batch = next_batch, close = close, schema = schema, token = token),
    class = "rducks_query_stream"
  )
  ready <- TRUE
  stream
}

#' @export
print.rducks_query_stream <- function(x, ...) {
  cat("<rducks_query_stream>\n")
  cat("  columns: ", paste(x$schema$names, collapse = ", "), "\n", sep = "")
  invisible(x)
}
