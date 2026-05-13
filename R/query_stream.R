rducks_query_stream_store <- function() {
  store <- .rducks_state$query_streams
  if (is.null(store)) {
    store <- new.env(parent = emptyenv())
    .rducks_state$query_streams <- store
  }
  store
}

rducks_query_stream_batch_store <- function() {
  store <- .rducks_state$query_stream_batches
  if (is.null(store)) {
    store <- new.env(parent = emptyenv())
    .rducks_state$query_stream_batches <- store
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
  if (is.null(state) || is.null(state$connection_token) || is.null(state$id)) return(invisible(NULL))
  store <- .rducks_state$query_streams
  if (!is.null(store) && exists(state$connection_token, envir = store, inherits = FALSE)) {
    token_store <- get(state$connection_token, envir = store, inherits = FALSE)
    if (exists(state$id, envir = token_store, inherits = FALSE)) {
      rm(list = state$id, envir = token_store)
    }
    if (!length(ls(envir = token_store, all.names = TRUE))) {
      rm(list = state$connection_token, envir = store)
    }
  }
  invisible(NULL)
}

rducks_query_stream_batch_key <- function(native_token) {
  paste0("batch::", native_token)
}

rducks_query_stream_store_arrow_batch <- function(native_token, array, schema, type_specs, column_names) {
  batch <- rducks_query_stream_materialize_arrow_batch(array, schema, type_specs, column_names)
  assign(rducks_query_stream_batch_key(native_token), batch, envir = rducks_query_stream_batch_store())
  TRUE
}

rducks_query_stream_take_arrow_batch <- function(native_token) {
  key <- rducks_query_stream_batch_key(native_token)
  store <- rducks_query_stream_batch_store()
  if (!exists(key, envir = store, inherits = FALSE)) {
    stop("Rducks query stream batch was not produced by the native stream", call. = FALSE)
  }
  batch <- get(key, envir = store, inherits = FALSE)
  rm(list = key, envir = store)
  batch
}

rducks_query_stream_type_from_native_spec <- function(spec) {
  kind <- spec$kind %||% ""
  switch(kind,
    null = NULL,
    scalar = rducks_type_object(spec$token),
    decimal = DECIMAL(spec$width, spec$scale),
    enum = ENUM(spec$levels),
    list = LIST(rducks_query_stream_type_from_native_spec(spec$child)),
    array = ARRAY(rducks_query_stream_type_from_native_spec(spec$child), spec$size),
    map = MAP(
      rducks_query_stream_type_from_native_spec(spec$key),
      rducks_query_stream_type_from_native_spec(spec$value)
    ),
    struct = {
      children <- lapply(spec$children, rducks_query_stream_type_from_native_spec)
      do.call(STRUCT, stats::setNames(children, spec$names))
    },
    union = {
      children <- lapply(spec$children, rducks_query_stream_type_from_native_spec)
      do.call(UNION, stats::setNames(children, spec$names))
    },
    stop("unsupported native Rducks query stream type kind: ", kind, call. = FALSE)
  )
}

rducks_query_stream_materialize_arrow_batch <- function(array, schema, type_specs, column_names) {
  if (!nanoarrow::nanoarrow_pointer_is_valid(array)) {
    stop("query stream nanoarrow array pointer is not valid", call. = FALSE)
  }
  if (!nanoarrow::nanoarrow_pointer_is_valid(schema)) {
    stop("query stream nanoarrow schema pointer is not valid", call. = FALSE)
  }
  n <- as.integer(array$length)
  type_specs <- as.list(type_specs)
  column_names <- as.character(column_names)
  if (length(type_specs) != length(column_names) || length(type_specs) != length(array$children)) {
    stop("query stream Arrow schema does not match native type metadata", call. = FALSE)
  }

  columns <- vector("list", length(type_specs))
  for (i in seq_along(type_specs)) {
    type <- rducks_query_stream_type_from_native_spec(type_specs[[i]])
    if (is.null(type)) {
      values <- rep(NA, n)
    } else {
      values <- rducks_arrow_array_to_values(type, array$children[[i]], schema$children[[i]])
    }
    if (length(values) != n) {
      stop("query stream column ", i, " materialized to length ", length(values), ", expected ", n, call. = FALSE)
    }
    columns[[i]] <- values
  }
  names(columns) <- column_names
  out <- structure(columns, class = "data.frame", row.names = .set_row_names(n))
  attr(out, "rducks_nanoarrow_schema") <- schema
  attr(out, "rducks_query_stream_types") <- lapply(type_specs, rducks_query_stream_type_from_native_spec)
  out
}

rducks_query_stream_native_open <- function(con, sql) {
  out <- DBI::dbGetQuery(
    con,
    sprintf("SELECT rducks_query_stream_open(%s) AS token", rducks_sql_string(sql))
  )$token[[1L]]
  if (!is.character(out) || length(out) != 1L || is.na(out) || !nzchar(out)) {
    stop("native Rducks query stream did not return a stream token", call. = FALSE)
  }
  out
}

rducks_query_stream_native_bool <- function(con, native_token, function_name) {
  out <- DBI::dbGetQuery(
    con,
    sprintf("SELECT %s(%s) AS ok", function_name, rducks_sql_string(native_token))
  )$ok[[1L]]
  isTRUE(out)
}

rducks_query_stream_native_schema <- function(con, native_token) {
  ok <- rducks_query_stream_native_bool(con, native_token, "rducks_query_stream_schema")
  if (!ok) stop("native Rducks query stream did not produce a schema batch", call. = FALSE)
  rducks_query_stream_take_arrow_batch(native_token)
}

rducks_query_stream_native_next <- function(con, native_token) {
  ok <- rducks_query_stream_native_bool(con, native_token, "rducks_query_stream_next")
  if (!ok) return(NULL)
  rducks_query_stream_take_arrow_batch(native_token)
}

rducks_query_stream_native_close <- function(con, native_token) {
  rducks_query_stream_native_bool(con, native_token, "rducks_query_stream_close")
}

rducks_query_stream_close_state <- function(state) {
  if (is.null(state) || isTRUE(state$closed)) return(invisible(FALSE))
  state$closed <- TRUE
  state$done <- TRUE
  con <- state$con
  native_token <- state$native_token
  state$pending <- NULL
  state$con <- NULL
  state$native_token <- NULL
  rducks_query_stream_unregister(state)
  if (!is.null(native_token)) {
    key <- rducks_query_stream_batch_key(native_token)
    store <- .rducks_state$query_stream_batches
    if (!is.null(store) && exists(key, envir = store, inherits = FALSE)) {
      rm(list = key, envir = store)
    }
  }
  if (!is.null(con) && !is.null(native_token)) {
    try(rducks_query_stream_native_close(con, native_token), silent = TRUE)
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
  state$connection_token <- token
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

rducks_query_stream_slice_batch <- function(batch, rows, schema = attr(batch, "rducks_nanoarrow_schema", exact = TRUE)) {
  out <- batch[rows, , drop = FALSE]
  row.names(out) <- seq_len(NROW(out))
  attr(out, "rducks_nanoarrow_schema") <- schema
  attr(out, "rducks_query_stream_types") <- attr(batch, "rducks_query_stream_types", exact = TRUE)
  out
}

rducks_query_stream_next_batch_state <- function(state, n = NULL) {
  if (is.null(state) || isTRUE(state$closed) || is.null(state$native_token) || is.null(state$con)) {
    stop("Rducks query stream is closed", call. = FALSE)
  }
  n <- if (is.null(n)) state$batch_size else rducks_query_stream_check_batch_size(n, "n")

  if (is.null(state$pending) || !NROW(state$pending)) {
    if (isTRUE(state$done)) return(NULL)
    state$pending <- tryCatch(
      rducks_query_stream_native_next(state$con, state$native_token),
      error = function(e) {
        rducks_query_stream_close_state(state)
        stop(conditionMessage(e), call. = FALSE)
      }
    )
    if (is.null(state$pending) || !NROW(state$pending)) {
      state$done <- TRUE
      state$pending <- NULL
      return(NULL)
    }
  }

  take <- min(n, NROW(state$pending))
  schema <- state$schema
  out <- rducks_query_stream_slice_batch(state$pending, seq_len(take), schema = schema)
  if (take < NROW(state$pending)) {
    state$pending <- rducks_query_stream_slice_batch(
      state$pending,
      seq.int(take + 1L, NROW(state$pending)),
      schema = schema
    )
  } else {
    state$pending <- NULL
  }
  out
}

#' Stream a DuckDB query in data-frame batches
#'
#' Opens a connection-bound query stream with explicit `next_batch()` and
#' `close()` methods. The query itself is executed by the Rducks DuckDB extension
#' using DuckDB's native streaming result and data-chunk APIs; Rducks converts
#' each fetched DuckDB chunk through DuckDB Arrow C Data and the package's
#' nanoarrow materializers. This is an R-side result/session API; it is not
#' inferred from scalar UDF IPC behavior and does not use the R-backed SQL table
#' function path. Because execution uses the extension-owned DuckDB connection,
#' database-scoped objects are visible but temporary tables/views that exist only
#' on the caller's DBI connection are not part of the stream query scope.
#'
#' `next_batch()` returns the next data-frame batch or `NULL` at end-of-stream.
#' Returned batches carry the stream's DuckDB/nanoarrow schema as the
#' `"rducks_nanoarrow_schema"` attribute. `close()` clears the native streaming
#' result; it is safe to call more than once. A finalizer also closes unclosed
#' streams, and `rducks_release(con)` closes streams registered on that
#' connection before detaching connection-local state.
#'
#' @param con A `duckdb_connection` with Rducks enabled.
#' @param sql SQL query string.
#' @param batch_size Maximum number of rows returned by `next_batch()` when its
#'   `n` argument is `NULL`. DuckDB may fetch a larger native chunk internally;
#'   Rducks buffers any remainder for later `next_batch()` calls.
#' @return Object of class `rducks_query_stream` with `next_batch(n = NULL)`,
#'   `close()`, `is_closed()`, `schema`, and `prototype` fields.
#' @export
rducks_query_stream <- function(con, sql, batch_size = 1024L) {
  rducks_assert_duckdb_connection(con)
  if (!is.character(sql) || length(sql) != 1L || is.na(sql) || !nzchar(sql)) {
    stop("sql must be a non-empty character scalar", call. = FALSE)
  }
  batch_size <- rducks_query_stream_check_batch_size(batch_size)
  rducks_runtime_token(con, required = TRUE)

  native_token <- rducks_query_stream_native_open(con, sql)
  state <- new.env(parent = emptyenv())
  state$con <- con
  state$native_token <- native_token
  state$closed <- FALSE
  state$done <- FALSE
  state$batch_size <- batch_size
  state$pending <- NULL

  ok <- FALSE
  on.exit({
    if (!ok) rducks_query_stream_close_state(state)
  }, add = TRUE)

  prototype <- rducks_query_stream_native_schema(con, native_token)
  schema <- attr(prototype, "rducks_nanoarrow_schema", exact = TRUE)
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
