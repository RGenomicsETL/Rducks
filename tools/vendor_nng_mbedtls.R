#!/usr/bin/env Rscript
# Vendor NNG + Mbed TLS sources for the experimental Rducks native NNG path.
#
# This script intentionally vendors source snapshots rather than relying on
# system libraries. Rducks can then build a hidden, statically linked NNG client
# shim inside the DuckDB extension without colliding with nanonext or ducknng.

`%||%` <- function(x, y) if (is.null(x)) y else x

args <- commandArgs(trailingOnly = TRUE)
force <- "--force" %in% args
cmd <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", cmd, value = TRUE)
script_path <- if (length(file_arg)) sub("^--file=", "", file_arg[[1L]]) else "tools/vendor_nng_mbedtls.R"
root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
third_party <- file.path(root, "inst", "rducks_extension", "third_party")

pins <- list(
  nng = list(
    name = "NNG",
    version = "1.11.0",
    tag = "v1.11",
    url = "https://github.com/nanomsg/nng/archive/refs/tags/v1.11.tar.gz",
    dir = "nng",
    keep = c("CMakeLists.txt", "LICENSE.txt", "README.adoc", "include", "src", "cmake", "docs/man")
  ),
  mbedtls = list(
    name = "Mbed TLS",
    version = "3.6.5",
    tag = "mbedtls-3.6.5",
    url = "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.5/mbedtls-3.6.5.tar.bz2",
    dir = "mbedtls",
    keep = c("CMakeLists.txt", "LICENSE", "include", "library", "cmake")
  )
)

copy_keep <- function(from, to, keep) {
  if (dir.exists(to)) unlink(to, recursive = TRUE, force = TRUE)
  dir.create(to, recursive = TRUE, showWarnings = FALSE)
  for (item in keep) {
    src <- file.path(from, item)
    dst <- file.path(to, item)
    if (!file.exists(src)) stop("expected vendored path missing: ", src, call. = FALSE)
    if (dir.exists(src)) {
      dir.create(dirname(dst), recursive = TRUE, showWarnings = FALSE)
      ok <- file.copy(src, dirname(dst), recursive = TRUE, copy.date = TRUE)
    } else {
      ok <- file.copy(src, dst, copy.date = TRUE)
    }
    if (!isTRUE(ok)) stop("failed to copy vendored path: ", src, call. = FALSE)
  }
  makefiles <- list.files(to, pattern = "^Makefile$", recursive = TRUE, full.names = TRUE, all.files = TRUE)
  if (length(makefiles)) unlink(makefiles, force = TRUE)
}

sha256 <- function(path) {
  unname(tools::sha256sum(path))
}

json_string <- function(x) {
  x <- gsub("\\\\", "\\\\\\\\", x)
  x <- gsub('"', '\\\\"', x)
  paste0('"', x, '"')
}

vendor_one <- function(id, spec, tmp) {
  dest <- file.path(third_party, spec$dir)
  if (dir.exists(dest) && !force) {
    message("Keeping existing ", spec$name, " vendor at ", dest, " (use --force to replace)")
    return(list(id = id, spec = spec, archive_sha256 = NA_character_))
  }

  archive <- file.path(tmp, paste0(id, ".tar.gz"))
  message("Downloading ", spec$name, " ", spec$tag)
  utils::download.file(spec$url, archive, mode = "wb", quiet = FALSE)
  extracted_before <- list.files(tmp, all.files = FALSE, full.names = TRUE)
  utils::untar(archive, exdir = tmp)
  extracted_after <- setdiff(list.files(tmp, all.files = FALSE, full.names = TRUE), extracted_before)
  dirs <- extracted_after[dir.exists(extracted_after)]
  if (length(dirs) != 1L) {
    stop("expected exactly one extracted directory for ", spec$name, call. = FALSE)
  }
  copy_keep(dirs[[1L]], dest, spec$keep)
  list(id = id, spec = spec, archive_sha256 = sha256(archive))
}

write_metadata <- function(records) {
  dir.create(third_party, recursive = TRUE, showWarnings = FALSE)
  now <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  lines <- c("{", paste0("  ", json_string("generated_at"), ": ", json_string(now), ","),
             paste0("  ", json_string("dependencies"), ": ["))
  dep_lines <- character()
  for (i in seq_along(records)) {
    rec <- records[[i]]
    spec <- rec$spec
    entry <- c(
      "    {",
      paste0("      ", json_string("id"), ": ", json_string(rec$id), ","),
      paste0("      ", json_string("name"), ": ", json_string(spec$name), ","),
      paste0("      ", json_string("version"), ": ", json_string(spec$version), ","),
      paste0("      ", json_string("tag"), ": ", json_string(spec$tag), ","),
      paste0("      ", json_string("url"), ": ", json_string(spec$url), ","),
      paste0("      ", json_string("archive_sha256"), ": ", json_string(rec$archive_sha256 %||% "")),
      paste0("    }", if (i < length(records)) "," else "")
    )
    dep_lines <- c(dep_lines, entry)
  }
  lines <- c(lines, dep_lines, "  ]", "}")
  writeLines(lines, file.path(third_party, "versions.json"), useBytes = TRUE)

  md <- c(
    "# Vendored native dependencies",
    "",
    "This directory contains source snapshots used by the experimental native",
    "NNG worker-provider sidequest. They are vendored so the Rducks DuckDB",
    "extension can statically link a hidden NNG client shim instead of depending",
    "on nanonext's private binary layout or any system `libnng` installation.",
    "",
    "## Pins",
    "",
    sprintf("- NNG `%s` (`%s`): %s", pins$nng$version, pins$nng$tag, pins$nng$url),
    sprintf("- Mbed TLS `%s` (`%s`): %s", pins$mbedtls$version, pins$mbedtls$tag, pins$mbedtls$url),
    "",
    "NNG is built with inproc, IPC/Unix-domain, TCP, and WebSocket transports",
    "enabled for the native worker path. Mbed TLS is vendored for the planned TLS",
    "transport, but TLS/WSS are not enabled until certificate and client-auth policy",
    "is explicit. Rducks does not use a system `libnng` or nanonext's private binary",
    "layout.",
    "",
    "## Update procedure",
    "",
    "Run from the package root:",
    "",
    "```sh",
    "Rscript tools/vendor_nng_mbedtls.R --force",
    "```",
    "",
    "Then rebuild the package and run at least:",
    "",
    "```sh",
    "RDUCKS_DEV_SURFACES=true make test",
    "```",
    "",
    "Keep raw NNG/MbedTLS calls behind `src/rducks_nng.c`; the rest of Rducks",
    "should talk to Rducks-owned provider/shim functions.",
    ""
  )
  writeLines(md, file.path(third_party, "VENDORING.md"), useBytes = TRUE)
}

dir.create(third_party, recursive = TRUE, showWarnings = FALSE)
tmp <- tempfile("rducks-vendor-")
dir.create(tmp)
on.exit(unlink(tmp, recursive = TRUE, force = TRUE), add = TRUE)
records <- Map(function(id, spec) vendor_one(id, spec, tmp), names(pins), pins)
write_metadata(records)
message("Vendored NNG/Mbed TLS sources under ", third_party)
