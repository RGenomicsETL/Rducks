rducks_query_stream_store <- function() {
  store <- .rducks_state$query_streams
  if (is.null(store)) {
    store <- new.env(parent = emptyenv())
    .rducks_state$query_streams <- store
  }
  store
}

rducks_query_stream_token_store <- function(token) {
  store <- rducks_query_stream_store()
  if (!exists(token, envir = store, inherits = FALSE)) {
    assign(token, new.env(parent = emptyenv()), envir = store)
  }
  get(token, envir = store, inherits = FALSE)
}

rducks_query_stream_next_id <- function() {
  counter <- .rducks_state$query_stream_counter %||% 0L
  counter <- counter + 1L
  .rducks_state$query_stream_counter <- counter
  paste0("rducks-query-stream-", counter)
}

rducks_query_stream_unregister <- function(state) {
  if (is.null(state) || is.null(state$token) || is.null(state$id)) return(invisible(NULL))
  store <- .rducks_state$query_streams
  if (!is.null(store) && exists(state$token, envir = store, inherits = FALSE)) {
    token_store <- get(state$token, envir = store, inherits = FALSE)
    if (exists(state$id, envir = token_store, inherits = FALSE)) {
      rm(list = state$id, envir = token_store)
    }
    if (!length(ls(envir = token_store, all.names = TRUE))) {
      rm(list = state$token, envir = store)
    }
  }
  invisible(NULL)
}

rducks_query_stream_close_state <- function(state) {
  if (is.null(state) || isTRUE(state$closed)) return(invisible(FALSE))
  state$closed <- TRUE
  state$done <- TRUE
  result <- state$result
  state$result <- NULL
  rducks_query_stream_unregister(state)
  if (!is.null(result)) {
    try(DBI::dbClearResult(result), silent = TRUE)
  }
  invisible(TRUE)
}

rducks_query_stream_close_for_token <- function(token) {
  store <- .rducks_state$query_streams
  if (is.null(store) || is.null(token) || is.na(token) || !exists(token, envir = store, inherits = FALSE)) {
    return(invisible(NULL))
  }
  token_store <- get(token, envir = store, inherits = FALSE)
  stream_ids <- ls(envir = token_store, all.names = TRUE)
  for (id in stream_ids) {
    state <- get(id, envir = token_store, inherits = FALSE)
    try(rducks_query_stream_close_state(state), silent = TRUE)
  }
  if (exists(token, envir = store, inherits = FALSE)) rm(list = token, envir = store)
  invisible(NULL)
}

rducks_query_stream_register <- function(con, state) {
  token <- rducks_connection_key(con)
  state$token <- token
  state$id <- rducks_query_stream_next_id()
  assign(state$id, state, envir = rducks_query_stream_token_store(token))
  invisible(state)
}

rducks_query_stream_check_batch_size <- function(batch_size, what = "batch_size") {
  if (!is.numeric(batch_size) || length(batch_size) != 1L || is.na(batch_size) ||
      !is.finite(batch_size) || batch_size < 1L || batch_size != as.integer(batch_size)) {
    stop(what, " must be a positive integer", call. = FALSE)
  }
  as.integer(batch_size)
}

rducks_query_stream_next_batch_state <- function(state, n = NULL) {
  if (is.null(state) || isTRUE(state$closed) || is.null(state$result)) {
    stop("Rducks query stream is closed", call. = FALSE)
  }
  if (isTRUE(state$done)) return(NULL)
  n <- if (is.null(n)) state$batch_size else rducks_query_stream_check_batch_size(n, "n")
  batch <- tryCatch(
    DBI::dbFetch(state$result, n = n),
    error = function(e) {
      rducks_query_stream_close_state(state)
      stop(conditionMessage(e), call. = FALSE)
    }
  )
  if (!NROW(batch)) {
    state$done <- TRUE
    return(NULL)
  }
  attr(batch, "rducks_nanoarrow_schema") <- state$schema
  batch
}

#' Stream a DuckDB query in data-frame batches
#'
#' Opens a connection-bound query stream with explicit `next_batch()` and
#' `close()` methods. This is an R-side streaming result/session API; it is not
#' inferred from scalar UDF IPC behavior and does not use the R-backed SQL table
#' function path.
#'
#' `next_batch()` returns the next data-frame batch or `NULL` at end-of-stream.
#' Returned batches carry the stream's inferred nanoarrow schema as the
#' `"rducks_nanoarrow_schema"` attribute. `close()` clears the underlying DBI
#' result; it is safe to call more than once. A finalizer also closes unclosed
#' streams, and `rducks_release(con)` closes streams registered on that
#' connection before detaching connection-local state.
#'
#' @param con A `duckdb_connection`.
#' @param sql SQL query string.
#' @param batch_size Default number of rows requested by `next_batch()`.
#' @return Object of class `rducks_query_stream` with `next_batch(n = NULL)`,
#'   `close()`, `is_closed()`, `schema`, and `prototype` fields.
#' @export
rducks_query_stream <- function(con, sql, batch_size = 1024L) {
  rducks_assert_duckdb_connection(con)
  if (!is.character(sql) || length(sql) != 1L || is.na(sql) || !nzchar(sql)) {
    stop("sql must be a non-empty character scalar", call. = FALSE)
  }
  batch_size <- rducks_query_stream_check_batch_size(batch_size)

  result <- DBI::dbSendQuery(con, sql)
  state <- new.env(parent = emptyenv())
  state$result <- result
  state$closed <- FALSE
  state$done <- FALSE
  state$batch_size <- batch_size

  ok <- FALSE
  on.exit({
    if (!ok) rducks_query_stream_close_state(state)
  }, add = TRUE)

  prototype <- DBI::dbFetch(result, n = 0L)
  schema <- nanoarrow::infer_nanoarrow_schema(prototype)
  state$prototype <- prototype
  state$schema <- schema
  rducks_query_stream_register(con, state)

  reg.finalizer(state, function(env) {
    try(rducks_query_stream_close_state(env), silent = TRUE)
    invisible(NULL)
  }, onexit = TRUE)

  stream <- structure(
    list(
      next_batch = function(n = NULL) rducks_query_stream_next_batch_state(state, n = n),
      close = function() rducks_query_stream_close_state(state),
      is_closed = function() isTRUE(state$closed),
      schema = schema,
      prototype = prototype,
      .state = state
    ),
    class = "rducks_query_stream"
  )
  ok <- TRUE
  stream
}

#' @export
print.rducks_query_stream <- function(x, ...) {
  cat("<rducks_query_stream>\n")
  cat("  closed:     ", if (isTRUE(x$is_closed())) "yes" else "no", "\n", sep = "")
  cat("  batch_size: ", x$.state$batch_size %||% NA_integer_, "\n", sep = "")
  cat("  columns:    ", paste(names(x$prototype), collapse = ", "), "\n", sep = "")
  invisible(x)
}
