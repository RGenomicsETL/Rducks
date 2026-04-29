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
#' Loads the bundled Rducks DuckDB extension and sets `PRAGMA threads=1` by
#' default for the current direct-R-callback implementation.
#'
#' @param con A `duckdb_connection`.
#' @param extension_path Extension path. Defaults to [rducks_extension_path()].
#' @param threads Either `"single"` or `"unchanged"`.
#' @return `con`, invisibly.
#' @export
rducks_enable <- function(con, extension_path = rducks_extension_path(),
                          threads = c("single", "unchanged")) {
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
