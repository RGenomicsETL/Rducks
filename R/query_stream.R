rducks_query_stream_store <- function() {
  rducks_get_or_init_store("query_streams")
}

rducks_query_stream_batch_store <- function() {
  rducks_get_or_init_store("query_stream_batches")
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

rducks_query_stream_arrow_batch <- function(array, schema, type_specs, column_names, type_objects = NULL) {
  if (!nanoarrow::nanoarrow_pointer_is_valid(array)) {
    stop("query stream nanoarrow array pointer is not valid", call. = FALSE)
  }
  if (!nanoarrow::nanoarrow_pointer_is_valid(schema)) {
    stop("query stream nanoarrow schema pointer is not valid", call. = FALSE)
  }
  type_specs <- as.list(type_specs)
  column_names <- as.character(column_names)
  if (length(type_specs) != length(column_names) || length(type_specs) != length(array$children)) {
    stop("query stream Arrow schema does not match native type metadata", call. = FALSE)
  }
  if (is.null(type_objects)) {
    type_objects <- lapply(type_specs, rducks_query_stream_type_from_native_spec)
  } else {
    type_objects <- as.list(type_objects)
    if (length(type_objects) != length(type_specs)) {
      stop("query stream type metadata does not match native type metadata", call. = FALSE)
    }
  }
  # DuckDB's Arrow C Data export filled `array`, and nanoarrow's owning
  # external pointer finalizer will call the ArrowArray release callback.
  # Attach the schema so callers can consume the struct array as a nanoarrow
  # record batch without forcing Rducks' data-frame materializer.
  nanoarrow::nanoarrow_array_set_schema(array, schema, validate = FALSE)
  structure(
    list(
      array = array,
      schema = schema,
      type_specs = type_specs,
      type_objects = type_objects,
      column_names = column_names
    ),
    class = "rducks_query_stream_arrow_batch"
  )
}

rducks_query_stream_store_arrow_batch <- function(native_token, array, schema, type_specs, column_names) {
  batch <- rducks_query_stream_arrow_batch(array, schema, type_specs, column_names)
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

rducks_query_stream_materialize_arrow_batch <- function(array, schema, type_specs, column_names, type_objects = NULL) {
  if (!nanoarrow::nanoarrow_pointer_is_valid(array)) {
    stop("query stream nanoarrow array pointer is not valid", call. = FALSE)
  }
  if (!nanoarrow::nanoarrow_pointer_is_valid(schema)) {
    stop("query stream nanoarrow schema pointer is not valid", call. = FALSE)
  }
  n_raw <- as.numeric(array$length)
  if (!is.finite(n_raw) || n_raw < 0 || n_raw > .Machine$integer.max || n_raw != floor(n_raw)) {
    stop("query stream batch is too large to materialize as an R data frame", call. = FALSE)
  }
  n <- as.integer(n_raw)
  type_specs <- as.list(type_specs)
  column_names <- as.character(column_names)
  if (length(type_specs) != length(column_names) || length(type_specs) != length(array$children)) {
    stop("query stream Arrow schema does not match native type metadata", call. = FALSE)
  }
  if (is.null(type_objects)) {
    type_objects <- lapply(type_specs, rducks_query_stream_type_from_native_spec)
  } else {
    type_objects <- as.list(type_objects)
    if (length(type_objects) != length(type_specs)) {
      stop("query stream type metadata does not match native type metadata", call. = FALSE)
    }
  }

  columns <- vector("list", length(type_specs))
  for (i in seq_along(type_specs)) {
    type <- type_objects[[i]]
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
  attr(out, "rducks_query_stream_types") <- type_objects
  out
}

rducks_query_stream_materialize_stored_arrow_batch <- function(batch) {
  rducks_query_stream_materialize_arrow_batch(
    batch$array,
    batch$schema,
    batch$type_specs,
    batch$column_names,
    type_objects = batch$type_objects
  )
}

rducks_query_stream_arrow_batch_nrow <- function(batch) {
  if (is.null(batch)) return(0L)
  n <- as.numeric(batch$array$length)
  if (!is.finite(n) || n < 0 || n > .Machine$integer.max || n != floor(n)) {
    stop("query stream batch row count is too large for R", call. = FALSE)
  }
  as.integer(n)
}

rducks_query_stream_record_batch_array <- function(batch) {
  array <- batch$array
  attr(array, "rducks_nanoarrow_schema") <- batch$schema
  attr(array, "rducks_query_stream_types") <- batch$type_objects
  attr(array, "rducks_query_stream_column_names") <- batch$column_names
  array
}

rducks_query_stream_set_arrow_batch_schema <- function(batch, schema) {
  batch$schema <- schema
  nanoarrow::nanoarrow_array_set_schema(batch$array, schema, validate = FALSE)
  batch
}

rducks_query_stream_slice_arrow_child <- function(child, start, n) {
  offset <- as.integer(child$offset %||% 0L)
  nanoarrow::nanoarrow_array_modify(
    child,
    list(offset = as.integer(offset + start - 1L), length = as.integer(n)),
    validate = FALSE
  )
}

rducks_query_stream_slice_arrow_batch <- function(batch, start = 1L, n = rducks_query_stream_arrow_batch_nrow(batch)) {
  start <- as.integer(start)
  n <- as.integer(n)
  if (is.na(start) || start < 1L || is.na(n) || n < 0L) {
    stop("invalid query stream Arrow batch slice", call. = FALSE)
  }
  total <- rducks_query_stream_arrow_batch_nrow(batch)
  if (start + n - 1L > total) {
    stop("query stream Arrow batch slice is outside the batch", call. = FALSE)
  }
  children <- lapply(batch$array$children, rducks_query_stream_slice_arrow_child, start = start, n = n)
  array <- nanoarrow::nanoarrow_array_modify(
    batch$array,
    list(offset = 0L, length = n, children = children),
    validate = FALSE
  )
  rducks_query_stream_arrow_batch(
    array,
    batch$schema,
    batch$type_specs,
    batch$column_names,
    type_objects = batch$type_objects
  )
}

rducks_query_stream_check_format <- function(format) {
  if (is.null(format)) return("data.frame")
  if (!is.character(format) || length(format) != 1L || is.na(format)) {
    stop("format must be a character scalar", call. = FALSE)
  }
  format <- match.arg(format, c("data.frame", "record_batch", "nanoarrow"))
  if (identical(format, "nanoarrow")) "record_batch" else format
}

rducks_query_stream_format_batch <- function(batch, format) {
  format <- rducks_query_stream_check_format(format)
  switch(format,
    data.frame = rducks_query_stream_materialize_stored_arrow_batch(batch),
    record_batch = rducks_query_stream_record_batch_array(batch),
    stop("unsupported query stream batch format", call. = FALSE)
  )
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

rducks_query_stream_close_native_quiet <- function(state) {
  if (is.null(state) || is.null(state$con) || is.null(state$native_token)) return(invisible(FALSE))
  try(rducks_query_stream_native_close(state$con, state$native_token), silent = TRUE)
  invisible(TRUE)
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
      !is.finite(batch_size) || batch_size < 1L || batch_size > .Machine$integer.max ||
      batch_size != floor(batch_size)) {
    stop(what, " must be a positive integer no larger than .Machine$integer.max", call. = FALSE)
  }
  as.integer(batch_size)
}

rducks_query_stream_next_batch_state <- function(state, n = NULL, format = NULL) {
  if (is.null(state) || isTRUE(state$closed) || is.null(state$native_token) || is.null(state$con)) {
    stop("Rducks query stream is closed", call. = FALSE)
  }
  n <- if (is.null(n)) state$batch_size else rducks_query_stream_check_batch_size(n, "n")
  format <- rducks_query_stream_check_format(format %||% state$format)

  if (is.null(state$pending) || !rducks_query_stream_arrow_batch_nrow(state$pending)) {
    if (isTRUE(state$done)) return(NULL)
    state$pending <- tryCatch(
      rducks_query_stream_native_next(state$con, state$native_token),
      error = function(e) {
        rducks_query_stream_close_state(state)
        stop(conditionMessage(e), call. = FALSE)
      }
    )
    if (is.null(state$pending) || !rducks_query_stream_arrow_batch_nrow(state$pending)) {
      state$done <- TRUE
      state$pending <- NULL
      rducks_query_stream_close_native_quiet(state)
      return(NULL)
    }
    state$pending <- rducks_query_stream_set_arrow_batch_schema(state$pending, state$schema)
  }

  pending_rows <- rducks_query_stream_arrow_batch_nrow(state$pending)
  take <- min(n, pending_rows)
  if (take == pending_rows) {
    out_batch <- state$pending
    state$pending <- NULL
  } else {
    out_batch <- rducks_query_stream_slice_arrow_batch(state$pending, start = 1L, n = take)
    state$pending <- rducks_query_stream_slice_arrow_batch(
      state$pending,
      start = take + 1L,
      n = pending_rows - take
    )
  }
  rducks_query_stream_format_batch(out_batch, format)
}

#' Stream a DuckDB query in batches
#'
#' Opens a connection-bound query stream with explicit `next_batch()` and
#' `close()` methods. The query itself is executed by the Rducks DuckDB extension
#' using DuckDB's native streaming result and data-chunk APIs; each fetched
#' DuckDB chunk is exported through DuckDB Arrow C Data. Rducks can either return
#' the owned nanoarrow record-batch object directly or materialize it with the
#' package's Rducks/nanoarrow helpers. This is an R-side result/session API; it
#' is not inferred from scalar UDF IPC behavior and does not use the R-backed SQL
#' table function path. Because execution uses a dedicated extension-owned
#' DuckDB connection, database-scoped objects are visible but temporary
#' tables/views that exist only on the caller's DBI connection are not part of
#' the stream query scope. That dedicated stream connection is separate from the
#' extension connection used for dynamic scalar/table/aggregate registration; a
#' caller connection currently supports one active native query stream at a
#' time. Delivery into R runs on the recorded R thread: even record-batch mode
#' creates R external-pointer objects and installs nanoarrow finalizers, so
#' Rducks does not call R/nanoarrow code from arbitrary DuckDB worker threads.
#'
#' `next_batch()` returns the next batch or `NULL` at end-of-stream. With
#' `format = "data.frame"` it returns a base R data-frame batch. With
#' `format = "record_batch"` it returns a `nanoarrow_array` struct array with an
#' attached `nanoarrow_schema`; nanoarrow's R finalizer owns the Arrow C Data
#' release callbacks, so callers can materialize later without Rducks copying the
#' batch to R vectors first. Returned batches carry the stream's DuckDB/nanoarrow
#' schema as the `"rducks_nanoarrow_schema"` attribute. `close()` clears the
#' native streaming result; it is safe to call more than once. A finalizer also
#' closes unclosed streams, and `rducks_release(con)` closes streams registered
#' on that connection before detaching connection-local state.
#'
#' @param con A `duckdb_connection` with Rducks enabled.
#' @param sql SQL query string.
#' @param batch_size Maximum number of rows returned by `next_batch()` when its
#'   `n` argument is `NULL`. DuckDB may fetch a larger native chunk internally;
#'   Rducks buffers any remainder for later `next_batch()` calls.
#' @param format Default batch representation. `"data.frame"` materializes
#'   batches to base R data frames. `"record_batch"` returns the owned
#'   `nanoarrow_array` record batch directly. `"nanoarrow"` is accepted as an
#'   alias for `"record_batch"`.
#' @return Object of class `rducks_query_stream` with
#'   `next_batch(n = NULL, format = NULL)`, `close()`, `is_closed()`, `schema`,
#'   and `prototype` fields.
#' @export
rducks_query_stream <- function(con, sql, batch_size = 1024L, format = c("data.frame", "record_batch", "nanoarrow")) {
  rducks_assert_duckdb_connection(con)
  if (!is.character(sql) || length(sql) != 1L || is.na(sql) || !nzchar(sql)) {
    stop("sql must be a non-empty character scalar", call. = FALSE)
  }
  batch_size <- rducks_query_stream_check_batch_size(batch_size)
  format <- rducks_query_stream_check_format(match.arg(format))
  rducks_runtime_token(con, required = TRUE)

  native_token <- rducks_query_stream_native_open(con, sql)
  state <- new.env(parent = emptyenv())
  state$con <- con
  state$native_token <- native_token
  state$closed <- FALSE
  state$done <- FALSE
  state$batch_size <- batch_size
  state$format <- format
  state$pending <- NULL

  ok <- FALSE
  on.exit({
    if (!ok) rducks_query_stream_close_state(state)
  }, add = TRUE)

  prototype_batch <- rducks_query_stream_native_schema(con, native_token)
  prototype <- rducks_query_stream_materialize_stored_arrow_batch(prototype_batch)
  schema <- prototype_batch$schema
  state$prototype <- prototype
  state$schema <- schema
  rducks_query_stream_register(con, state)

  reg.finalizer(state, function(env) {
    try(rducks_query_stream_close_state(env), silent = TRUE)
    invisible(NULL)
  }, onexit = TRUE)

  stream <- structure(
    list(
      next_batch = function(n = NULL, format = NULL) rducks_query_stream_next_batch_state(state, n = n, format = format),
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
  cat("  format:     ", x$.state$format %||% "data.frame", "\n", sep = "")
  cat("  columns:    ", paste(names(x$prototype), collapse = ", "), "\n", sep = "")
  invisible(x)
}
