# Programmatically derive the unstable DuckDB C extension ABI entries that
# Rducks source code currently calls.

rducks_duckdb_capi_header <- function(root = ".") {
  capi_root <- file.path(root, "tools", "ext", "duckdb_capi")
  versions_file <- file.path(capi_root, "versions.txt")
  versions <- trimws(sub("#.*$", "", readLines(versions_file, warn = FALSE)))
  versions <- versions[nzchar(versions)]
  if (!length(versions)) stop("DuckDB version manifest is empty", call. = FALSE)
  file.path(capi_root, tail(versions, 1L), "duckdb_extension.h")
}

# Headers before DuckDB 1.5.6 label API groups with "// Version <name>" comment
# markers: "v1.2.0" for the stable surface and "unstable_*" for the unstable
# groups. From 1.5.6 the header is banded instead: every entry sits under
# "#if DUCKDB_API_VERSION_AT_LEAST(a, b, c)", and deprecated entries carry a
# "DUCKDB_API_ALLOW_DEPRECATED" clause in that guard. Both formats map onto
# abi_group: the marker name for the old format, "v<a>.<b>.<c>" or "deprecated"
# for the banded format.
rducks_read_duckdb_extension_api <- function(header = rducks_duckdb_capi_header()) {
  lines <- readLines(header, warn = FALSE)
  current_group <- "stable"
  band_group <- NULL
  out <- list()
  n <- 0L

  for (line in lines) {
    version_match <- regexec("^// Version[[:space:]]+([^[:space:]]+)", line)
    version_parts <- regmatches(line, version_match)[[1L]]
    if (length(version_parts)) {
      current_group <- version_parts[[2L]]
      next
    }

    if (grepl("^#if[[:space:]]", line)) {
      band_group <- NULL
      if (grepl("DUCKDB_API_ALLOW_DEPRECATED", line, fixed = TRUE)) {
        band_group <- "deprecated"
      } else {
        band_match <- regexec(
          "DUCKDB_API_VERSION_AT_LEAST\\(([0-9]+),[[:space:]]*([0-9]+),[[:space:]]*([0-9]+)\\)",
          line
        )
        band_parts <- regmatches(line, band_match)[[1L]]
        if (length(band_parts)) {
          band_group <- sprintf("v%s.%s.%s", band_parts[[2L]], band_parts[[3L]], band_parts[[4L]])
        }
      }
      next
    }
    if (grepl("^#endif", line)) {
      band_group <- NULL
      next
    }

    define_match <- regexec("^#define[[:space:]]+(duckdb_[A-Za-z0-9_]+)\\b", line)
    define_parts <- regmatches(line, define_match)[[1L]]
    if (length(define_parts)) {
      n <- n + 1L
      out[[n]] <- data.frame(
        function_name = define_parts[[2L]],
        abi_group = if (is.null(band_group)) current_group else band_group,
        stringsAsFactors = FALSE
      )
    }
  }

  if (!length(out)) {
    return(data.frame(function_name = character(), abi_group = character()))
  }
  do.call(rbind, out)
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
    list.files(
      file.path(root, "tools", "ext", "src"),
      pattern = "\\.c$",
      full.names = TRUE
    )
  )
}

# Entries outside the v1.2.0 stable surface: the unstable_* groups of pre-1.5.6
# headers, and for banded (1.5.6+) headers the deprecated entries plus every
# band above v1.2.0. v1.2.0 is the stable surface the older headers exposed, so
# the report stays comparable across header formats.
rducks_api_group_outside_stable_baseline <- function(abi_group) {
  if (startsWith(abi_group, "unstable") || identical(abi_group, "deprecated")) return(TRUE)
  if (grepl("^v[0-9]+\\.[0-9]+\\.[0-9]+$", abi_group)) {
    return(utils::compareVersion(sub("^v", "", abi_group), "1.2.0") > 0L)
  }
  FALSE
}

rducks_used_duckdb_unstable_api <- function(root = ".") {
  api <- rducks_read_duckdb_extension_api(rducks_duckdb_capi_header(root))
  outside <- vapply(api$abi_group, rducks_api_group_outside_stable_baseline, logical(1L), USE.NAMES = FALSE)
  unstable <- api[outside, , drop = FALSE]
  if (!nrow(unstable)) return(unstable)

  out <- list()
  n <- 0L
  for (file in rducks_extension_source_files(root)) {
    if (!file.exists(file)) next
    text <- rducks_strip_c_comments_and_strings(readLines(file, warn = FALSE))
    tokens <- unique(unlist(regmatches(
      text,
      gregexpr("\\bduckdb_[A-Za-z0-9_]+\\b", text, perl = TRUE)
    )))
    used <- intersect(tokens, unstable$function_name)
    if (!length(used)) next

    matched <- merge(
      data.frame(function_name = used, stringsAsFactors = FALSE),
      unstable,
      by = "function_name",
      all.x = TRUE,
      sort = FALSE
    )
    matched$file <- sub(paste0("^", gsub("([\\.^$|?*+(){}])", "\\\\\\1", normalizePath(root, mustWork = FALSE)), "/?"), "", normalizePath(file, mustWork = FALSE))
    n <- n + 1L
    out[[n]] <- matched
  }

  if (!length(out)) {
    return(data.frame(function_name = character(), abi_group = character(), file = character()))
  }

  used <- unique(do.call(rbind, out))
  used[order(used$abi_group, used$function_name, used$file), , drop = FALSE]
}

rducks_used_duckdb_unstable_api_summary <- function(root = ".") {
  used <- rducks_used_duckdb_unstable_api(root)
  if (!nrow(used)) {
    return(data.frame(abi_group = character(), functions = character(), count = integer()))
  }

  groups <- split(used$function_name, used$abi_group)
  data.frame(
    abi_group = names(groups),
    functions = vapply(groups, function(x) {
      paste(sprintf("`%s`", sort(unique(x))), collapse = ", ")
    }, character(1L)),
    count = vapply(groups, function(x) length(unique(x)), integer(1L)),
    row.names = NULL,
    stringsAsFactors = FALSE
  )
}

rducks_used_duckdb_unstable_api_markdown <- function(root = ".") {
  summary <- rducks_used_duckdb_unstable_api_summary(root)
  if (!nrow(summary)) {
    return("No DuckDB C extension API entries outside the v1.2.0 stable surface were detected.\n")
  }

  lines <- c(
    "| ABI group | Functions used | Count |",
    "| --- | --- | ---: |"
  )
  lines <- c(
    lines,
    sprintf("| `%s` | %s | %d |", summary$abi_group, summary$functions, summary$count)
  )
  paste0(paste(lines, collapse = "\n"), "\n")
}
