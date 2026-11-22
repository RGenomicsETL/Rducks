# CI runtime policy. The minimum duckdb version in DESCRIPTION is the single
# authority: the bundled stable C API extension loads on that engine and on
# every later one.

rducks_minimum_duckdb_version <- function(root = ".") {
  imports <- read.dcf(file.path(root, "DESCRIPTION"), fields = "Imports")[1L, 1L]
  if (is.na(imports)) {
    stop("DESCRIPTION has no Imports field", call. = FALSE)
  }
  version <- regmatches(imports, regexec("duckdb \\(>= ([0-9]+\\.[0-9]+\\.[0-9]+)\\)", imports))[[1L]]
  if (length(version) != 2L) {
    stop("DESCRIPTION must import duckdb with a minimum release version", call. = FALSE)
  }
  paste0("v", version[[2L]])
}

# "supported" pins the minimum release; "latest" installs the newest package.
rducks_ci_duckdb_package <- function(policy = c("supported", "latest"), root = ".") {
  policy <- match.arg(policy)
  if (policy == "latest") return("duckdb")
  paste0("duckdb@", sub("^v", "", rducks_minimum_duckdb_version(root)))
}

rducks_check_ci_duckdb_runtime <- function(version, policy = c("supported", "latest"), root = ".") {
  policy <- match.arg(policy)
  minimum <- rducks_minimum_duckdb_version(root)
  parse <- function(v) numeric_version(sub("^v", "", sub("-.*$", "", v)))
  if (!grepl("^v?[0-9]+\\.[0-9]+\\.[0-9]+", version)) {
    stop("DuckDB engine version '", version, "' is not a release version", call. = FALSE)
  }
  if (policy == "supported" && parse(version) != parse(minimum)) {
    stop("Supported-runtime coverage requires DuckDB ", minimum, "; got ", version, call. = FALSE)
  }
  if (parse(version) < parse(minimum)) {
    stop("DuckDB ", version, " is older than the minimum ", minimum,
         " for the ", policy, " runtime check", call. = FALSE)
  }
  message("DuckDB engine ", version, " accepted for ", policy, " runtime coverage")
  invisible(version)
}
