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

#' Stream a DuckDB query as native data-frame batches
#'
#' Opens a native DuckDB streaming result through the Rducks extension and
#' returns the rows in DuckDB-sized batches as data frames, instead of an eager
#' `DBI::dbGetQuery()` result. Each batch is materialized directly from DuckDB
#' vectors to R values on the recorded R thread. The stream uses the extension's
#' database-scoped connection, so
#' it cannot see caller-connection temporary tables or views.
#'
#' @param con A `duckdb_connection` with Rducks enabled.
#' @param sql A non-empty SQL query string.
#' @return An object of class `rducks_query_stream` with `$next_batch()`
#'   (returns the next data-frame batch, or `NULL` at end of stream),
#'   `$close()`, `$schema` (column names and Rducks type tokens), and `$token`.
#'   The stream closes on `$close()` or `rducks_release(con)`.
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
  token <- DBI::dbGetQuery(
    con, sprintf("SELECT rducks_query_stream_open(%s) AS token", rducks_sql_string(sql))
  )$token[[1L]]
  metadata <- DBI::dbGetQuery(
    con, sprintf("SELECT rducks_query_stream_metadata(%s) AS metadata", rducks_sql_string(token))
  )$metadata[[1L]]
  schema <- rducks_query_stream_parse_metadata(metadata)

  closed <- FALSE
  finalize_batch <- function(batch) {
    cols <- batch$columns
    if (length(schema$names) == length(cols)) names(cols) <- schema$names
    structure(cols, class = "data.frame", row.names = .set_row_names(batch$n))
  }
  next_batch <- function() {
    if (closed) {
      return(NULL)
    }
    has_batch <- DBI::dbGetQuery(
      con, sprintf("SELECT rducks_query_stream_next(%s) AS has_batch", rducks_sql_string(token))
    )$has_batch[[1L]]
    if (!isTRUE(has_batch)) {
      return(NULL)
    }
    batch <- rducks_query_stream_take_native_batch(token)
    if (is.null(batch)) {
      return(NULL)
    }
    finalize_batch(batch)
  }
  close <- function() {
    if (closed) {
      return(invisible(NULL))
    }
    closed <<- TRUE
    try(
      DBI::dbGetQuery(con, sprintf("SELECT rducks_query_stream_close(%s) AS closed", rducks_sql_string(token))),
      silent = TRUE
    )
    rducks_query_stream_take_native_batch(token)
    invisible(NULL)
  }

  structure(
    list(next_batch = next_batch, close = close, schema = schema, token = token),
    class = "rducks_query_stream"
  )
}

#' @export
print.rducks_query_stream <- function(x, ...) {
  cat("<rducks_query_stream>\n")
  cat("  columns: ", paste(x$schema$names, collapse = ", "), "\n", sep = "")
  invisible(x)
}
