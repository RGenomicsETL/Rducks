# Signed local extension repository.
#
# Installation signs the bundled extension with a key generated for that
# installation and keeps only the public key (rducks_extension/build/rducks.pub).
# rducks_enable() exposes the signed file as a DuckDB extension repository
# under tempdir(), registers the public key for that repository, and runs
# INSTALL/LOAD FROM it, so DuckDB's signature checks stay enabled.

# Oldest DuckDB engine with extension repositories (CREATE EXTENSION
# REPOSITORY, LOAD ... FROM). Keep in sync with the duckdb requirement in
# DESCRIPTION.
rducks_min_duckdb_version <- "v2.0.0"

#' DuckDB configuration for a connection that loads Rducks
#'
#' Returns `config` with the two settings that let
#' \code{\link[=rducks_enable]{rducks_enable()}} load the signed Rducks extension
#' without writing to the home directory: extension repositories are allowed,
#' and DuckDB keeps its extension repository records in a directory below
#' [tempdir()]. DuckDB accepts `extension_repository_directory` only at
#' startup, so pass the result to [duckdb::duckdb()].
#'
#' @param config A named list of further DuckDB configuration options. Entries
#'   for `allow_extension_repositories` or `extension_repository_directory`
#'   are kept as given.
#' @return A named list for the `config` argument of [duckdb::duckdb()].
#' @examples
#' \donttest{
#' db <- DBI::dbConnect(duckdb::duckdb(config = rducks_duckdb_config()))
#' rducks_enable(db)
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
#' @export
rducks_duckdb_config <- function(config = list()) {
  if (!is.list(config) || (length(config) && (is.null(names(config)) || !all(nzchar(names(config)))))) {
    stop("config must be a named list", call. = FALSE)
  }
  defaults <- list(
    allow_extension_repositories = "allowed",
    extension_repository_directory = rducks_session_dir("registry")
  )
  c(config, defaults[setdiff(names(defaults), names(config))])
}

# Counts repository registrations so that each name is unique in the session.
rducks_repository_state <- new.env(parent = emptyenv())
rducks_repository_state$count <- 0L

rducks_session_dir <- function(name) {
  file.path(tempdir(), "rducks", name)
}

rducks_extension_public_key <- function() {
  path <- system.file("rducks_extension", "build", "rducks.pub", package = "Rducks", mustWork = TRUE)
  key <- readLines(path, warn = FALSE)
  if (length(key) != 1L || !grepl("^[A-Za-z0-9+/]+=*$", key)) {
    stop("the installed Rducks public key is malformed: ", path, call. = FALSE)
  }
  key
}

rducks_current_setting <- function(con, name) {
  DBI::dbGetQuery(con, sprintf("SELECT current_setting(%s) AS value", rducks_sql_string(name)))$value[[1L]]
}

rducks_assert_engine_has_repositories <- function(con) {
  engine <- DBI::dbGetQuery(con, "SELECT library_version FROM pragma_version()")$library_version[[1L]]
  if (rducks_parse_duckdb_version(engine, "DuckDB engine version") <
      rducks_parse_duckdb_version(rducks_min_duckdb_version, "minimum DuckDB version")) {
    stop(
      "Rducks loads its signed extension from a DuckDB extension repository, which needs DuckDB ",
      rducks_min_duckdb_version, " or later; this connection runs DuckDB ", engine, ".",
      call. = FALSE
    )
  }
  invisible(TRUE)
}

# DuckDB installs from <prefix>/<version directory>/<platform>/; the version
# directory is the release tag, or the source id for development builds.
rducks_repository_prefix <- function(con, extension_path) {
  version <- DBI::dbGetQuery(con, "SELECT library_version, source_id FROM pragma_version()")
  version_dir <- if (grepl("^v[0-9]+\\.[0-9]+\\.[0-9]+$", version$library_version[[1L]])) {
    version$library_version[[1L]]
  } else {
    version$source_id[[1L]]
  }
  platform <- DBI::dbGetQuery(con, "PRAGMA platform")$platform[[1L]]
  prefix <- rducks_session_dir("repository")
  target_dir <- file.path(prefix, version_dir, platform)
  target <- file.path(target_dir, basename(extension_path))
  if (!file.exists(target)) {
    dir.create(target_dir, recursive = TRUE, showWarnings = FALSE)
    if (!file.copy(extension_path, target)) {
      stop("failed to stage the Rducks extension repository under ", prefix, call. = FALSE)
    }
  }
  normalizePath(prefix, mustWork = TRUE)
}

# duckdb-r 2.0.0 classifies CREATE EXTENSION REPOSITORY as a LOAD statement
# and coerces its result row (the repository name, prefix and key fingerprint)
# to a row count, which warns "NAs introduced by coercion". Muffle exactly that
# warning for this one statement; errors and other warnings propagate.
rducks_create_repository <- function(con, sql) {
  withCallingHandlers(
    DBI::dbExecute(con, sql),
    warning = function(w) {
      call <- conditionCall(w)
      if (identical(conditionMessage(w), "NAs introduced by coercion") &&
          is.call(call) && identical(call[[1L]], quote(duckdb_post_execute))) {
        invokeRestart("muffleWarning")
      }
    }
  )
}

rducks_load_from_repository <- function(con, extension_path, home_registry) {
  rducks_assert_engine_has_repositories(con)
  access <- rducks_current_setting(con, "allow_extension_repositories")
  if (identical(access, "forbidden")) {
    stop(
      "this connection forbids extension repositories (allow_extension_repositories = 'forbidden'), ",
      "so Rducks cannot load its signed extension.",
      call. = FALSE
    )
  }
  if (!nzchar(rducks_current_setting(con, "extension_repository_directory")) && !isTRUE(home_registry)) {
    stop(
      "this connection keeps extension repository records in ~/.duckdb/extension_repositories. ",
      "Open it with duckdb::duckdb(config = rducks_duckdb_config()), or pass home_registry = TRUE ",
      "to let rducks_enable() write a record there while it loads the extension.",
      call. = FALSE
    )
  }
  prefix <- rducks_repository_prefix(con, extension_path)
  if (identical(access, "undecided")) {
    DBI::dbExecute(con, "SET allow_extension_repositories = 'allowed'")
  }

  rducks_repository_state$count <- rducks_repository_state$count + 1L
  repository <- sprintf("rducks_%d_%d", Sys.getpid(), rducks_repository_state$count)
  extension_directory <- rducks_current_setting(con, "extension_directory")
  on.exit({
    DBI::dbExecute(con, sprintf("SET extension_directory = %s", rducks_sql_string(extension_directory)))
    DBI::dbExecute(con, sprintf("DROP EXTENSION REPOSITORY IF EXISTS %s", repository))
  }, add = TRUE)
  rducks_create_repository(con, sprintf(
    "CREATE EXTENSION REPOSITORY %s WITH PREFIX %s USING PUBLIC KEY %s",
    repository, rducks_sql_string(prefix), rducks_sql_string(rducks_extension_public_key())
  ))
  DBI::dbExecute(con, sprintf(
    "SET extension_directory = %s", rducks_sql_string(rducks_session_dir("extensions"))
  ))
  DBI::dbExecute(con, sprintf("FORCE INSTALL rducks FROM %s", repository))
  DBI::dbExecute(con, sprintf("LOAD rducks FROM %s", repository))
  invisible(TRUE)
}
