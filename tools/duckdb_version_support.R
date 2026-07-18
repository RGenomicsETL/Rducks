# Read and render the exact DuckDB versions declared for bundled extension builds.
# This file is sourced by generated documentation; versions.txt remains the
# single source of truth.

rducks_supported_duckdb_versions <- function(root = ".") {
  path <- file.path(root, "tools", "ext", "duckdb_capi", "versions.txt")
  if (!file.exists(path)) {
    stop("DuckDB version manifest not found: ", path, call. = FALSE)
  }

  versions <- trimws(sub("#.*$", "", readLines(path, warn = FALSE)))
  versions <- versions[nzchar(versions)]
  if (!length(versions)) {
    stop("DuckDB version manifest is empty: ", path, call. = FALSE)
  }
  if (any(!grepl("^v[0-9]+\\.[0-9]+\\.[0-9]+$", versions))) {
    stop("DuckDB version manifest contains a non-release version", call. = FALSE)
  }
  if (anyDuplicated(versions)) {
    stop("DuckDB version manifest contains duplicate versions", call. = FALSE)
  }

  normalized <- numeric_version(sub("^v", "", versions))
  paste0("v", as.character(sort(normalized)))
}

rducks_duckdb_version_range <- function(root = ".") {
  versions <- rducks_supported_duckdb_versions(root)
  if (length(versions) == 1L) return(versions)
  paste(versions[[1L]], "through", versions[[length(versions)]])
}

rducks_duckdb_version_support_markdown <- function(root = ".") {
  versions <- rducks_supported_duckdb_versions(root)
  paste(
    c(
      "| DuckDB engine version | Bundled extension |",
      "|:--|:--|",
      sprintf("| `%s` | yes |", versions)
    ),
    collapse = "\n"
  )
}
