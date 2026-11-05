# Read and render the exact DuckDB versions declared for bundled extension builds.
# Documentation and CI runtime selection share the versions.txt authority.

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

rducks_ci_duckdb_package <- function(policy = c("supported", "latest"), root = ".") {
  policy <- match.arg(policy)
  if (policy == "latest") return("duckdb")
  versions <- rducks_supported_duckdb_versions(root)
  paste0("duckdb@", sub("^v", "", tail(versions, 1L)))
}

rducks_check_ci_duckdb_runtime <- function(version, policy = c("supported", "latest"), root = ".") {
  policy <- match.arg(policy)
  versions <- rducks_supported_duckdb_versions(root)
  if (!version %in% versions) {
    stop(
      "DuckDB ", version, " is not bundled for the ", policy, " runtime check. ",
      "Bundled versions: ", paste(versions, collapse = ", "), ". ",
      "Vendor its headers and declare the engine version before running the matrix.",
      call. = FALSE
    )
  }
  expected <- tail(versions, 1L)
  if (policy == "supported" && version != expected) {
    stop("Supported-runtime coverage requires DuckDB ", expected, "; got ", version, call. = FALSE)
  }
  message("DuckDB engine ", version, " accepted for ", policy, " runtime coverage")
  invisible(version)
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
