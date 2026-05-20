#!/usr/bin/env Rscript
# Fetch and repair the exact DuckDB C API headers used by the Rducks extension.
#
# This is an explicit vendoring tool, not an install-time network step.
# Usage:
#   Rscript tools/fetch_duckdb_headers.R --ref v1.5.0
#   Rscript tools/fetch_duckdb_headers.R --repo /path/to/duckdb --ref v1.5.0

args <- commandArgs(trailingOnly = TRUE)

parse_args <- function(args) {
  out <- list()
  i <- 1L
  while (i <= length(args)) {
    key <- args[[i]]
    if (startsWith(key, "--") && i + 1L <= length(args)) {
      out[[substring(key, 3L)]] <- args[[i + 1L]]
      i <- i + 2L
    } else {
      stop("expected --name value argument near: ", key, call. = FALSE)
    }
  }
  out
}

`%||%` <- function(x, y) if (is.null(x) || !nzchar(x)) y else x

cmd <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", cmd, value = TRUE)
script_file <- if (length(file_arg)) sub("^--file=", "", file_arg[[1L]]) else "tools/fetch_duckdb_headers.R"
repo_root <- normalizePath(dirname(dirname(script_file)), mustWork = FALSE)
if (!file.exists(file.path(repo_root, "DESCRIPTION"))) {
  repo_root <- normalizePath(getwd(), mustWork = TRUE)
}

opts <- parse_args(args)
ref <- opts[["ref"]] %||% Sys.getenv("RDUCKS_DUCKDB_REF", unset = "v1.5.0")
dest <- opts[["dest"]] %||% file.path(repo_root, "tools", "ext", "duckdb_capi")
source_repo <- opts[["repo"]] %||% ""

dest <- normalizePath(dest, mustWork = FALSE)
dir.create(dest, recursive = TRUE, showWarnings = FALSE)

header_paths <- c(
  duckdb = "src/include/duckdb.h",
  duckdb_extension = "src/include/duckdb_extension.h"
)

read_header <- function(name, relpath) {
  if (nzchar(source_repo)) {
    path <- file.path(normalizePath(source_repo, mustWork = TRUE), relpath)
    if (!file.exists(path)) {
      stop("DuckDB header not found in explicit repo: ", path, call. = FALSE)
    }
    return(readChar(path, file.info(path)$size, useBytes = TRUE))
  }

  url <- sprintf(
    "https://raw.githubusercontent.com/duckdb/duckdb/%s/%s",
    ref,
    relpath
  )
  tmp <- tempfile(fileext = paste0("-", basename(relpath)))
  status <- tryCatch(
    utils::download.file(url, tmp, mode = "wb", quiet = FALSE),
    error = function(e) e
  )
  if (inherits(status, "error") || !identical(status, 0L)) {
    stop("failed to download DuckDB header: ", url, call. = FALSE)
  }
  readChar(tmp, file.info(tmp)$size, useBytes = TRUE)
}

repair_fixed <- function(text, replacements) {
  counts <- integer(length(replacements))
  names(counts) <- names(replacements)
  for (nm in names(replacements)) {
    pair <- replacements[[nm]]
    old <- pair[[1L]]
    new <- pair[[2L]]
    matches <- gregexpr(old, text, fixed = TRUE)[[1L]]
    n <- if (identical(matches, -1L)) 0L else length(matches)
    counts[[nm]] <- n
    text <- gsub(old, new, text, fixed = TRUE)
  }
  list(text = text, counts = counts)
}

repair_duckdb_h <- function(text) {
  repair_fixed(text, list(
    duckdb_create_instance_cache = c(
      "DUCKDB_C_API duckdb_instance_cache duckdb_create_instance_cache();",
      "DUCKDB_C_API duckdb_instance_cache duckdb_create_instance_cache(void);"
    ),
    duckdb_library_version = c(
      "DUCKDB_C_API const char *duckdb_library_version();",
      "DUCKDB_C_API const char *duckdb_library_version(void);"
    ),
    duckdb_config_count = c(
      "DUCKDB_C_API size_t duckdb_config_count();",
      "DUCKDB_C_API size_t duckdb_config_count(void);"
    ),
    duckdb_vector_size = c(
      "DUCKDB_C_API idx_t duckdb_vector_size();",
      "DUCKDB_C_API idx_t duckdb_vector_size(void);"
    ),
    duckdb_create_null_value = c(
      "DUCKDB_C_API duckdb_value duckdb_create_null_value();",
      "DUCKDB_C_API duckdb_value duckdb_create_null_value(void);"
    ),
    duckdb_create_scalar_function = c(
      "DUCKDB_C_API duckdb_scalar_function duckdb_create_scalar_function();",
      "DUCKDB_C_API duckdb_scalar_function duckdb_create_scalar_function(void);"
    ),
    duckdb_create_aggregate_function = c(
      "DUCKDB_C_API duckdb_aggregate_function duckdb_create_aggregate_function();",
      "DUCKDB_C_API duckdb_aggregate_function duckdb_create_aggregate_function(void);"
    ),
    duckdb_create_table_function = c(
      "DUCKDB_C_API duckdb_table_function duckdb_create_table_function();",
      "DUCKDB_C_API duckdb_table_function duckdb_create_table_function(void);"
    ),
    duckdb_create_cast_function = c(
      "DUCKDB_C_API duckdb_cast_function duckdb_create_cast_function();",
      "DUCKDB_C_API duckdb_cast_function duckdb_create_cast_function(void);"
    )
  ))
}

repair_duckdb_extension_h <- function(text) {
  repair_fixed(text, list(
    duckdb_library_version = c(
      "const char *(*duckdb_library_version)();",
      "const char *(*duckdb_library_version)(void);"
    ),
    duckdb_config_count = c(
      "size_t (*duckdb_config_count)();",
      "size_t (*duckdb_config_count)(void);"
    ),
    duckdb_vector_size = c(
      "idx_t (*duckdb_vector_size)();",
      "idx_t (*duckdb_vector_size)(void);"
    ),
    duckdb_create_null_value = c(
      "duckdb_value (*duckdb_create_null_value)();",
      "duckdb_value (*duckdb_create_null_value)(void);"
    ),
    duckdb_create_scalar_function = c(
      "duckdb_scalar_function (*duckdb_create_scalar_function)();",
      "duckdb_scalar_function (*duckdb_create_scalar_function)(void);"
    ),
    duckdb_create_aggregate_function = c(
      "duckdb_aggregate_function (*duckdb_create_aggregate_function)();",
      "duckdb_aggregate_function (*duckdb_create_aggregate_function)(void);"
    ),
    duckdb_create_table_function = c(
      "duckdb_table_function (*duckdb_create_table_function)();",
      "duckdb_table_function (*duckdb_create_table_function)(void);"
    ),
    duckdb_create_cast_function = c(
      "duckdb_cast_function (*duckdb_create_cast_function)();",
      "duckdb_cast_function (*duckdb_create_cast_function)(void);"
    ),
    duckdb_create_instance_cache = c(
      "duckdb_instance_cache (*duckdb_create_instance_cache)();",
      "duckdb_instance_cache (*duckdb_create_instance_cache)(void);"
    )
  ))
}

write_header <- function(filename, text) {
  path <- file.path(dest, filename)
  writeChar(text, path, eos = NULL, useBytes = TRUE)
  path
}

repairers <- list(
  duckdb = repair_duckdb_h,
  duckdb_extension = repair_duckdb_extension_h
)

written <- list()
for (nm in names(header_paths)) {
  message("Fetching ", header_paths[[nm]], " @ ", ref)
  raw <- read_header(nm, header_paths[[nm]])
  repaired <- repairers[[nm]](raw)
  filename <- paste0(nm, ".h")
  path <- write_header(filename, repaired$text)
  written[[filename]] <- list(path = path, repairs = repaired$counts)
}

json_quote <- function(x) {
  x <- gsub("\\\\", "\\\\\\\\", x)
  x <- gsub('"', '\\"', x)
  paste0('"', x, '"')
}

metadata_lines <- c(
  "{",
  paste0("  \"duckdb_ref\": ", json_quote(ref), ","),
  paste0("  \"source\": ", json_quote(if (nzchar(source_repo)) normalizePath(source_repo, mustWork = TRUE) else "https://github.com/duckdb/duckdb"), ","),
  "  \"headers\": {"
)
file_entries <- character()
for (filename in names(written)) {
  path <- written[[filename]]$path
  md5 <- unname(tools::md5sum(path))
  repair_entries <- paste(
    sprintf("      \"%s\": %d", names(written[[filename]]$repairs), as.integer(written[[filename]]$repairs)),
    collapse = ",\n"
  )
  file_entries <- c(file_entries, paste0(
    "    ", json_quote(filename), ": {\n",
    "      \"path\": ", json_quote(file.path("tools", "ext", "duckdb_capi", filename)), ",\n",
    "      \"md5\": ", json_quote(md5), ",\n",
    "      \"repairs\": {\n", repair_entries, "\n      }\n",
    "    }"
  ))
}
metadata_lines <- c(metadata_lines, paste(file_entries, collapse = ",\n"), "  }", "}")
writeLines(metadata_lines, file.path(dest, "duckdb_headers.json"), useBytes = TRUE)

message("Wrote repaired DuckDB C API headers to: ", dest)
for (filename in names(written)) {
  repairs <- written[[filename]]$repairs
  message("  ", filename, ": ", sum(repairs), " repair(s)")
}
