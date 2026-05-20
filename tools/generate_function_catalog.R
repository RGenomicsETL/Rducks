#!/usr/bin/env Rscript
# Render the JSON-formatted Rducks function catalog to Markdown.
# Uses only base R so package checks do not need jsonlite as a dependency.

cmd <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", cmd, value = TRUE)
script_file <- if (length(file_arg)) sub("^--file=", "", file_arg[[1L]]) else "tools/generate_function_catalog.R"
root <- normalizePath(dirname(dirname(script_file)), mustWork = FALSE)
if (!file.exists(file.path(root, "DESCRIPTION"))) {
  root <- normalizePath(getwd(), mustWork = TRUE)
}

catalog <- file.path(root, "inst", "function_catalog", "functions.json")
out <- file.path(root, "inst", "function_catalog", "functions.md")

parse_json <- function(text) {
  i <- 1L
  n <- nchar(text, type = "chars")

  chr <- function(k = i) substr(text, k, k)
  skip_ws <- function() {
    while (i <= n && chr(i) %in% c(" ", "\t", "\r", "\n")) {
      i <<- i + 1L
    }
  }
  expect <- function(x) {
    if (chr(i) != x) {
      stop("invalid JSON: expected '", x, "' at byte ", i, call. = FALSE)
    }
    i <<- i + 1L
  }
  parse_string <- function() {
    expect('"')
    out <- character()
    while (i <= n) {
      ch <- chr(i)
      if (ch == '"') {
        i <<- i + 1L
        return(paste0(out, collapse = ""))
      }
      if (ch == "\\") {
        i <<- i + 1L
        esc <- chr(i)
        if (esc %in% c('"', "\\", "/")) {
          out <- c(out, esc)
        } else if (esc == "b") {
          out <- c(out, "\b")
        } else if (esc == "f") {
          out <- c(out, "\f")
        } else if (esc == "n") {
          out <- c(out, "\n")
        } else if (esc == "r") {
          out <- c(out, "\r")
        } else if (esc == "t") {
          out <- c(out, "\t")
        } else if (esc == "u") {
          hex <- substr(text, i + 1L, i + 4L)
          code <- strtoi(hex, base = 16L)
          if (is.na(code)) {
            stop("invalid JSON unicode escape at byte ", i, call. = FALSE)
          }
          out <- c(out, intToUtf8(code))
          i <<- i + 4L
        } else {
          stop("invalid JSON string escape at byte ", i, call. = FALSE)
        }
      } else {
        out <- c(out, ch)
      }
      i <<- i + 1L
    }
    stop("invalid JSON: unterminated string", call. = FALSE)
  }
  parse_literal <- function(lit, value) {
    if (substr(text, i, i + nchar(lit) - 1L) != lit) {
      stop("invalid JSON literal at byte ", i, call. = FALSE)
    }
    i <<- i + nchar(lit)
    value
  }
  parse_number <- function() {
    start <- i
    while (i <= n && grepl("[-+0-9.eE]", chr(i))) {
      i <<- i + 1L
    }
    as.numeric(substr(text, start, i - 1L))
  }
  parse_array <- function() {
    expect("[")
    skip_ws()
    values <- list()
    if (chr(i) == "]") {
      i <<- i + 1L
      return(values)
    }
    repeat {
      values[[length(values) + 1L]] <- parse_value()
      skip_ws()
      if (chr(i) == "]") {
        i <<- i + 1L
        return(values)
      }
      expect(",")
      skip_ws()
    }
  }
  parse_object <- function() {
    expect("{")
    skip_ws()
    value <- list()
    if (chr(i) == "}") {
      i <<- i + 1L
      return(value)
    }
    repeat {
      key <- parse_string()
      skip_ws()
      expect(":")
      skip_ws()
      value[[key]] <- parse_value()
      skip_ws()
      if (chr(i) == "}") {
        i <<- i + 1L
        return(value)
      }
      expect(",")
      skip_ws()
    }
  }
  parse_value <- function() {
    skip_ws()
    ch <- chr(i)
    if (ch == '"') return(parse_string())
    if (ch == "{") return(parse_object())
    if (ch == "[") return(parse_array())
    if (ch == "t") return(parse_literal("true", TRUE))
    if (ch == "f") return(parse_literal("false", FALSE))
    if (ch == "n") return(parse_literal("null", NULL))
    parse_number()
  }

  value <- parse_value()
  skip_ws()
  if (i <= n) {
    stop("invalid JSON: trailing content at byte ", i, call. = FALSE)
  }
  value
}

items <- parse_json(paste(readLines(catalog, warn = FALSE), collapse = "\n"))

md_inline_code <- function(x) {
  paste0("`", x, "`")
}

json_array_chr <- function(x) {
  if (is.null(x) || !length(x)) return(character())
  vapply(x, as.character, character(1L))
}

md_inline_code_list <- function(x) {
  values <- json_array_chr(x)
  if (!length(values)) return(NULL)
  paste(md_inline_code(values), collapse = ", ")
}

item_field <- function(item, name) {
  value <- item[[name]]
  if (is.null(value) || !length(value)) NULL else value
}

required <- c("name", "kind", "category", "signature", "returns", "description")
for (idx in seq_along(items)) {
  missing <- required[!vapply(required, function(field) {
    value <- item_field(items[[idx]], field)
    !is.null(value) && nzchar(as.character(value[[1L]]))
  }, logical(1L))]
  if (length(missing)) {
    stop(
      "function catalog item ", idx, " is missing required field(s): ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
}

lines <- c(
  "# Rducks Function Catalog",
  "",
  "Generated from `inst/function_catalog/functions.json` by",
  "`tools/generate_function_catalog.R`.",
  ""
)
for (item in items) {
  aliases <- md_inline_code_list(item_field(item, "aliases"))
  notes <- json_array_chr(item_field(item, "notes"))
  examples <- json_array_chr(item_field(item, "examples"))
  details <- c(
    sprintf("- Kind: %s", md_inline_code(item$kind)),
    sprintf("- Category: %s", md_inline_code(item$category)),
    sprintf("- Signature: %s", md_inline_code(item$signature)),
    sprintf("- Returns: %s", md_inline_code(item$returns))
  )
  if (!is.null(aliases)) details <- c(details, sprintf("- Aliases: %s", aliases))
  if (!is.null(item_field(item, "lifecycle"))) {
    details <- c(details, sprintf("- Lifecycle: %s", md_inline_code(item$lifecycle)))
  }
  if (!is.null(item_field(item, "since"))) {
    details <- c(details, sprintf("- Since: %s", md_inline_code(item$since)))
  }

  lines <- c(lines, sprintf("## %s", md_inline_code(item$name)), "", details, "", item$description)
  if (length(notes)) {
    lines <- c(lines, "", "Notes:", "", paste0("- ", notes))
  }
  if (length(examples)) {
    lines <- c(lines, "", "Examples:", "", paste0("- ", examples))
  }
  lines <- c(lines, "")
}

writeLines(lines, out, useBytes = TRUE)
message("Wrote ", out)
