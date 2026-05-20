# Programmatically derive the unstable DuckDB C extension ABI entries that
# Rducks source code currently calls.

rducks_read_duckdb_extension_api <- function(header = file.path(
  "tools", "ext", "duckdb_capi", "duckdb_extension.h"
)) {
  lines <- readLines(header, warn = FALSE)
  current_group <- "stable"
  out <- list()
  n <- 0L

  for (line in lines) {
    version_match <- regexec("^// Version[[:space:]]+([^[:space:]]+)", line)
    version_parts <- regmatches(line, version_match)[[1L]]
    if (length(version_parts)) {
      current_group <- version_parts[[2L]]
      next
    }

    define_match <- regexec("^#define[[:space:]]+(duckdb_[A-Za-z0-9_]+)\\b", line)
    define_parts <- regmatches(line, define_match)[[1L]]
    if (length(define_parts)) {
      n <- n + 1L
      out[[n]] <- data.frame(
        function_name = define_parts[[2L]],
        abi_group = current_group,
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

rducks_used_duckdb_unstable_api <- function(root = ".") {
  api <- rducks_read_duckdb_extension_api(file.path(
    root, "tools", "ext", "duckdb_capi", "duckdb_extension.h"
  ))
  unstable <- api[startsWith(api$abi_group, "unstable"), , drop = FALSE]
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
    return("No unstable DuckDB C extension API entries were detected.\n")
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
