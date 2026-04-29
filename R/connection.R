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
#' Loads the bundled Rducks DuckDB extension. The current direct R callback
#' execution mode requires single-thread DuckDB execution; pass
#' `threads = "single"` to set `PRAGMA threads=1` explicitly.
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

  if (identical(threads, "single")) {
    DBI::dbExecute(con, "PRAGMA threads=1")
  }

  invisible(con)
}

rducks_sql_string <- function(x) {
  sprintf("'%s'", gsub("'", "''", x, fixed = TRUE))
}

rducks_connection_threads <- function(con) {
  value <- tryCatch(
    DBI::dbGetQuery(con, "SELECT current_setting('threads') AS threads")$threads[[1L]],
    error = function(e) NA
  )
  suppressWarnings(as.integer(value))
}

rducks_assert_single_thread <- function(con) {
  threads <- rducks_connection_threads(con)
  if (!identical(threads, 1L)) {
    stop(
      "direct Rducks callbacks require single-thread DuckDB execution; ",
      "call rducks_enable(con, threads = 'single') or set PRAGMA threads=1 ",
      "before registering R UDFs",
      call. = FALSE
    )
  }
  invisible(TRUE)
}
