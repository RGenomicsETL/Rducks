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
#' Loads the bundled Rducks DuckDB extension. The current scalar-mode R UDF
#' execution path requires R API work to happen on the calling R thread; pass
#' `threads = "single"` to set `external_threads=1` and `PRAGMA threads=1`
#' explicitly for the supported scalar-mode R UDF configuration.
#'
#' @param con A `duckdb_connection`.
#' @param extension_path Extension path. Defaults to [rducks_extension_path()].
#' @param threads Either `"unchanged"` or `"single"`.
#' @return `con`, invisibly.
#' @export
rducks_enable <- function(con, extension_path = rducks_extension_path(),
                          threads = c("unchanged", "single")) {
  threads <- match.arg(threads)
  if (!inherits(con, "duckdb_connection")) {
    stop("con must be a duckdb_connection", call. = FALSE)
  }

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
    DBI::dbExecute(con, "SET external_threads=1")
    DBI::dbExecute(con, "PRAGMA threads=1")
  }

  invisible(con)
}

rducks_sql_string <- function(x) {
  sprintf("'%s'", gsub("'", "''", x, fixed = TRUE))
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
