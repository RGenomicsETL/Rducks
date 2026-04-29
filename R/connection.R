#' Locate the installed Rducks DuckDB extension artifact
#'
#' @return Character scalar path, or `NA_character_` if no artifact is bundled.
#' @export
rducks_extension_path <- function() {
  candidates <- c(
    system.file("duckdb_extension", "rducks.duckdb_extension", package = "Rducks", mustWork = FALSE),
    system.file("duckdb_extension", "rducks", "rducks.duckdb_extension", package = "Rducks", mustWork = FALSE)
  )
  candidates <- candidates[nzchar(candidates) & file.exists(candidates)]
  if (length(candidates)) {
    normalizePath(candidates[[1]], mustWork = TRUE)
  } else {
    NA_character_
  }
}

#' Enable Rducks on a DuckDB connection
#'
#' Loads the Rducks DuckDB extension artifact when one is available and applies
#' optional connection settings used by safe R callback execution.
#'
#' @param con A `duckdb_connection`.
#' @param extension_path Optional extension path. If `NULL`,
#'   [rducks_extension_path()] is used.
#' @param threads Either `"unchanged"` or `"single"`. `"single"` executes
#'   `PRAGMA threads=1`, which is the first safe mode for direct main-thread R
#'   callbacks.
#' @param required If `TRUE`, error when no extension artifact is available.
#' @return `con`, invisibly.
#' @export
rducks_enable <- function(con, extension_path = NULL,
                          threads = c("unchanged", "single"),
                          required = FALSE) {
  threads <- match.arg(threads)
  if (!inherits(con, "duckdb_connection")) {
    stop("con must be a duckdb_connection", call. = FALSE)
  }

  if (is.null(extension_path)) {
    extension_path <- rducks_extension_path()
  }

  if (!is.na(extension_path) && nzchar(extension_path)) {
    path_sql <- gsub("'", "''", normalizePath(extension_path, mustWork = TRUE), fixed = TRUE)
    DBI::dbExecute(con, sprintf("LOAD '%s'", path_sql))
  } else if (isTRUE(required)) {
    stop("no bundled Rducks DuckDB extension artifact found", call. = FALSE)
  }

  if (identical(threads, "single")) {
    DBI::dbExecute(con, "PRAGMA threads=1")
  }

  invisible(con)
}
