#!/usr/bin/env Rscript
# Vendor the small nanoarrow C/IPC subset used by Rducks.
#
# This is intentionally separate from the runtime `nanoarrow` R package. The R
# package supplies R-side headers/classes; this snapshot supplies private C/IPC
# implementation code compiled into the Rducks extension and package DLL.

`%||%` <- function(x, y) if (is.null(x)) y else x

args <- commandArgs(trailingOnly = TRUE)
force <- "--force" %in% args
value_arg <- function(name, default = NULL) {
  prefix <- paste0(name, "=")
  hit <- grep(paste0("^", prefix), args, value = TRUE)
  if (length(hit)) sub(prefix, "", hit[[1L]], fixed = TRUE) else default
}

cmd <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", cmd, value = TRUE)
script_path <- if (length(file_arg)) sub("^--file=", "", file_arg[[1L]]) else "tools/vendor_nanoarrow.R"
root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
third_party <- file.path(root, "tools", "ext", "third_party")
dest <- file.path(third_party, "na")

pin <- list(
  id = "nanoarrow",
  name = "Apache Arrow nanoarrow C/IPC",
  version = value_arg("--version", "0.9.0.dev-4639910"),
  ref = value_arg("--ref", "4639910"),
  tag = value_arg("--tag", "apache-arrow-nanoarrow-0.9.0.dev-23-g4639910"),
  url = value_arg("--url", "https://github.com/apache/arrow-nanoarrow/archive/4639910.tar.gz"),
  namespace = "RducksNanoarrow",
  layout = "tools/ext/third_party/na"
)

keep <- c(
  "LICENSE.txt",
  "src/nanoarrow/nanoarrow_config.h",
  "src/nanoarrow/nanoarrow.h",
  "src/nanoarrow/nanoarrow_ipc.h",
  "src/nanoarrow/common/array.c",
  "src/nanoarrow/common/array_stream.c",
  "src/nanoarrow/common/inline_array.h",
  "src/nanoarrow/common/inline_buffer.h",
  "src/nanoarrow/common/inline_types.h",
  "src/nanoarrow/common/schema.c",
  "src/nanoarrow/common/utils.c",
  "src/nanoarrow/ipc/codecs.c",
  "src/nanoarrow/ipc/decoder.c",
  "src/nanoarrow/ipc/encoder.c",
  "src/nanoarrow/ipc/flatcc_generated.h",
  "src/nanoarrow/ipc/reader.c",
  "src/nanoarrow/ipc/writer.c",
  "flatcc/LICENSE",
  "flatcc/include/flatcc",
  "flatcc/src/runtime/builder.c",
  "flatcc/src/runtime/emitter.c",
  "flatcc/src/runtime/refmap.c",
  "flatcc/src/runtime/verifier.c"
)

copy_path <- function(from, to) {
  if (!file.exists(from)) stop("expected nanoarrow vendor path missing: ", from, call. = FALSE)
  dir.create(dirname(to), recursive = TRUE, showWarnings = FALSE)
  ok <- if (dir.exists(from)) {
    if (dir.exists(to)) unlink(to, recursive = TRUE, force = TRUE)
    dir.create(to, recursive = TRUE, showWarnings = FALSE)
    files <- list.files(from, all.files = TRUE, no.. = TRUE, full.names = TRUE)
    if (!length(files)) TRUE else all(file.copy(files, to, recursive = TRUE, copy.date = TRUE))
  } else {
    file.copy(from, to, copy.date = TRUE, overwrite = TRUE)
  }
  if (!isTRUE(ok)) stop("failed to copy nanoarrow vendor path: ", from, call. = FALSE)
}

copy_keep <- function(from, to) {
  if (dir.exists(to)) unlink(to, recursive = TRUE, force = TRUE)
  dir.create(to, recursive = TRUE, showWarnings = FALSE)
  for (item in keep) {
    source_item <- if (startsWith(item, "flatcc/")) file.path("thirdparty", item) else item
    copy_path(file.path(from, source_item), file.path(to, item))
  }
}

sha256 <- function(path) unname(tools::sha256sum(path))
json_string <- function(x) {
  x <- gsub("\\\\", "\\\\\\\\", x)
  x <- gsub('"', '\\\\"', x)
  paste0('"', x, '"')
}

vendor_source <- function(tmp) {
  repo <- value_arg("--repo")
  if (!is.null(repo)) {
    repo <- normalizePath(repo, mustWork = TRUE)
    message("Vendoring nanoarrow from ", repo)
    return(list(path = repo, archive_sha256 = NA_character_))
  }

  archive <- file.path(tmp, "nanoarrow.tar.gz")
  message("Downloading nanoarrow ", pin$ref)
  utils::download.file(pin$url, archive, mode = "wb", quiet = FALSE)
  before <- list.files(tmp, all.files = FALSE, full.names = TRUE)
  utils::untar(archive, exdir = tmp)
  after <- setdiff(list.files(tmp, all.files = FALSE, full.names = TRUE), before)
  dirs <- after[dir.exists(after)]
  if (length(dirs) != 1L) stop("expected one extracted nanoarrow directory", call. = FALSE)
  list(path = dirs[[1L]], archive_sha256 = sha256(archive))
}

nanoarrow_metadata_lines <- function(record, indent = "  ", trailing_comma = FALSE) {
  archive_sha256 <- record$archive_sha256 %||% ""
  if (is.na(archive_sha256)) archive_sha256 <- ""
  c(
    paste0(indent, "{"),
    paste0(indent, "  ", json_string("id"), ": ", json_string(pin$id), ","),
    paste0(indent, "  ", json_string("name"), ": ", json_string(pin$name), ","),
    paste0(indent, "  ", json_string("version"), ": ", json_string(pin$version), ","),
    paste0(indent, "  ", json_string("tag"), ": ", json_string(pin$tag), ","),
    paste0(indent, "  ", json_string("commit"), ": ", json_string(pin$ref), ","),
    paste0(indent, "  ", json_string("url"), ": ", json_string(pin$url), ","),
    paste0(indent, "  ", json_string("archive_sha256"), ": ", json_string(archive_sha256), ","),
    paste0(indent, "  ", json_string("namespace"), ": ", json_string(pin$namespace), ","),
    paste0(indent, "  ", json_string("layout"), ": ", json_string(pin$layout)),
    paste0(indent, "}", if (trailing_comma) "," else "")
  )
}

write_nanoarrow_metadata <- function(record) {
  dir.create(third_party, recursive = TRUE, showWarnings = FALSE)
  writeLines(nanoarrow_metadata_lines(record, indent = ""),
             file.path(third_party, "nanoarrow.json"), useBytes = TRUE)
}

write_versions_metadata <- function(record) {
  path <- file.path(third_party, "versions.json")
  if (!file.exists(path)) return(invisible(NULL))
  lines <- readLines(path, warn = FALSE)
  id_line <- grep('"id": "nanoarrow"', lines, fixed = TRUE)
  if (length(id_line) != 1L) return(invisible(NULL))
  start <- max(which(seq_along(lines) <= id_line & grepl('^    \\{$', lines)))
  end_candidates <- which(seq_along(lines) >= id_line & grepl('^    \\},?$', lines))
  if (!length(start) || !length(end_candidates)) return(invisible(NULL))
  end <- end_candidates[[1L]]
  replacement <- nanoarrow_metadata_lines(record, indent = "    ", trailing_comma = grepl(',$', lines[[end]]))
  lines <- c(lines[seq_len(start - 1L)], replacement, lines[(end + 1L):length(lines)])
  writeLines(lines, path, useBytes = TRUE)
  invisible(NULL)
}

if (dir.exists(dest) && !force) {
  stop("nanoarrow vendor directory already exists: ", dest, " (use --force to replace)", call. = FALSE)
}

tmp <- tempfile("rducks-nanoarrow-")
dir.create(tmp)
on.exit(unlink(tmp, recursive = TRUE, force = TRUE), add = TRUE)
source <- vendor_source(tmp)
copy_keep(source$path, dest)
write_nanoarrow_metadata(source)
write_versions_metadata(source)
message("Vendored nanoarrow C/IPC subset under ", dest)
