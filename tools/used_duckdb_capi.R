# Report the DuckDB C extension API that Rducks targets, the minimum duckdb
# version of the package, and the C API entries that the extension source
# calls, grouped by the API version band of the vendored header. Sourced by
# README.Rmd.

rducks_duckdb_capi_dir <- function(root = ".") {
  file.path(root, "tools", "ext", "duckdb_capi")
}

# The minimum duckdb version declared in DESCRIPTION, for example "2.0.0".
rducks_duckdb_min_version <- function(root = ".") {
  imports <- read.dcf(file.path(root, "DESCRIPTION"), fields = "Imports")[1L, 1L]
  version <- regmatches(imports, regexec("duckdb \\(>= ([0-9.]+)\\)", imports))[[1L]]
  if (length(version) != 2L) {
    stop("DESCRIPTION must import duckdb with a minimum version", call. = FALSE)
  }
  version[[2L]]
}

# The vendored header release is the stable C extension API version that
# configure targets, and thus the oldest engine that can load the extension.
rducks_duckdb_capi_version <- function(root = ".") {
  path <- file.path(rducks_duckdb_capi_dir(root), "duckdb_headers.json")
  lines <- readLines(path, warn = FALSE)
  ref <- regmatches(lines, regexec('"duckdb_ref":[[:space:]]*"(v[0-9]+\\.[0-9]+\\.[0-9]+)"', lines))
  ref <- unlist(lapply(ref[lengths(ref) == 2L], `[`, 2L))
  if (length(ref) != 1L) {
    stop("duckdb_headers.json must record exactly one duckdb_ref release: ", path, call. = FALSE)
  }
  ref
}

# Entries in the banded header sit under "#if DUCKDB_API_VERSION_AT_LEAST(a, b,
# c)"; deprecated entries carry a "DUCKDB_API_ALLOW_DEPRECATED" clause in that
# guard. abi_group is "v<a>.<b>.<c>" or "deprecated".
rducks_read_duckdb_extension_api <- function(root = ".") {
  lines <- readLines(file.path(rducks_duckdb_capi_dir(root), "duckdb_extension.h"), warn = FALSE)
  band_group <- NA_character_
  groups <- rep(NA_character_, length(lines))
  for (i in seq_along(lines)) {
    line <- lines[[i]]
    if (grepl("^#if[[:space:]]", line)) {
      band_parts <- regmatches(line, regexec(
        "DUCKDB_API_VERSION_AT_LEAST\\(([0-9]+),[[:space:]]*([0-9]+),[[:space:]]*([0-9]+)\\)",
        line
      ))[[1L]]
      band_group <- if (grepl("DUCKDB_API_ALLOW_DEPRECATED", line, fixed = TRUE)) {
        "deprecated"
      } else if (length(band_parts)) {
        sprintf("v%s.%s.%s", band_parts[[2L]], band_parts[[3L]], band_parts[[4L]])
      } else {
        NA_character_
      }
    } else if (grepl("^#endif", line)) {
      band_group <- NA_character_
    }
    groups[[i]] <- band_group
  }

  defines <- regmatches(lines, regexec("^#define[[:space:]]+(duckdb_[A-Za-z0-9_]+)\\b", lines))
  is_define <- lengths(defines) == 2L & !is.na(groups)
  data.frame(
    function_name = vapply(defines[is_define], `[`, character(1L), 2L),
    abi_group = groups[is_define],
    stringsAsFactors = FALSE
  )
}

rducks_strip_c_comments_and_strings <- function(text) {
  text <- paste(text, collapse = "\n")
  text <- gsub("/\\*([^*]|\\*+[^*/])*\\*+/", " ", text, perl = TRUE)
  text <- gsub("//[^\n]*", " ", text, perl = TRUE)
  text <- gsub("\"(\\\\.|[^\"\\\\])*\"", "\"\"", text, perl = TRUE)
  text <- gsub("'(\\\\.|[^'\\\\])*'", "''", text, perl = TRUE)
  text
}

rducks_extension_source_files <- function(root = ".") {
  c(
    file.path(root, "tools", "ext", "rducks_extension.c"),
    list.files(file.path(root, "tools", "ext", "src"), pattern = "\\.c$", full.names = TRUE)
  )
}

rducks_used_duckdb_capi <- function(root = ".") {
  api <- rducks_read_duckdb_extension_api(root)
  tokens <- unique(unlist(lapply(rducks_extension_source_files(root), function(file) {
    text <- rducks_strip_c_comments_and_strings(readLines(file, warn = FALSE))
    regmatches(text, gregexpr("\\bduckdb_[A-Za-z0-9_]+\\b", text, perl = TRUE))[[1L]]
  })))
  used <- api[api$function_name %in% tokens, , drop = FALSE]
  used[order(used$abi_group, used$function_name), , drop = FALSE]
}

rducks_used_duckdb_capi_markdown <- function(root = ".") {
  used <- rducks_used_duckdb_capi(root)
  groups <- split(used$function_name, used$abi_group)
  bands <- names(groups)
  bands <- c(setdiff(bands, "deprecated")[order(numeric_version(sub("^v", "", setdiff(bands, "deprecated"))))],
             intersect(bands, "deprecated"))
  lines <- c(
    "| API band | Count | Functions used |",
    "| --- | ---: | --- |",
    vapply(bands, function(band) {
      fns <- sort(unique(groups[[band]]))
      sprintf("| `%s` | %d | %s |", band, length(fns), paste(sprintf("`%s`", fns), collapse = ", "))
    }, character(1L))
  )
  paste0(paste(lines, collapse = "\n"), "\n")
}
