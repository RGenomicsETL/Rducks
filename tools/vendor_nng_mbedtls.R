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
third_party <- file.path(root, "tools", "ext", "third_party")

pins <- list(
  nng = list(
    name = "NNG",
    version = "1.11.0",
    tag = "v1.11",
    url = "https://github.com/nanomsg/nng/archive/refs/tags/v1.11.tar.gz",
    dir = "nng",
    keep = c("CMakeLists.txt", "LICENSE.txt", "README.adoc", "include", "src", "cmake")
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

patch_nng_cmake <- function(dest) {
  cmake_file <- file.path(dest, "CMakeLists.txt")
  lines <- readLines(cmake_file, warn = FALSE)
  old <- "add_subdirectory(docs/man)"
  at <- which(lines == old)
  if (length(at) != 1L) {
    stop("expected one NNG docs/man CMake entry in ", cmake_file, call. = FALSE)
  }
  replacement <- c(
    "# Build bundled documentation only when the optional docs snapshot is present.",
    "# Rducks vendors NNG as a private static implementation detail and does not",
    "# need NNG manpages in the R source package.",
    "if (EXISTS \"${CMAKE_CURRENT_SOURCE_DIR}/docs/man/CMakeLists.txt\")",
    "    add_subdirectory(docs/man)",
    "endif ()"
  )
  lines <- c(lines[seq_len(at - 1L)], replacement, lines[(at + 1L):length(lines)])
  writeLines(lines, cmake_file, useBytes = TRUE)
}

patch_nng_windows_rtools_clock <- function(dest) {
  cmake_file <- file.path(dest, "src", "platform", "windows", "CMakeLists.txt")
  cmake <- readLines(cmake_file, warn = FALSE)
  cmake_old <- c(
    "    if (NOT NNG_HAVE_CONDVAR OR NOT NNG_HAVE_SNPRINTF OR NOT NNG_HAVE_TIMESPEC_GET)",
    "        message(FATAL_ERROR",
    "                \"Modern Windows API support is missing. \",",
    "                \"Versions of Windows prior to Vista are not supported.  \",",
    "                \"Further, the legacy MinGW environments are not supported. \",",
    "                \"Ensure you have at least Windows Vista or newer, and are \",",
    "                \"using either Visual Studio 2013 or compatible compiler, \",",
    "                \"and are also using the universal C runtime (UCRT).\")",
    "    endif ()"
  )
  cmake_new <- c(
    "    if (NOT NNG_HAVE_CONDVAR OR NOT NNG_HAVE_SNPRINTF)",
    "        message(FATAL_ERROR",
    "                \"Modern Windows API support is missing. \",",
    "                \"Versions of Windows prior to Vista are not supported.  \",",
    "                \"Ensure you have at least Windows Vista or newer, and are \",",
    "                \"using either Visual Studio 2013 or compatible compiler, \",",
    "                \"and are also using a runtime that provides snprintf() and condition variables.\")",
    "    endif ()"
  )
  cmake_text <- paste(cmake, collapse = "\n")
  cmake_old_text <- paste(cmake_old, collapse = "\n")
  if (!grepl(cmake_old_text, cmake_text, fixed = TRUE)) {
    stop("expected NNG Windows CMake timespec_get gate in ", cmake_file, call. = FALSE)
  }
  writeLines(strsplit(sub(cmake_old_text, paste(cmake_new, collapse = "\n"), cmake_text, fixed = TRUE), "\n", fixed = TRUE)[[1L]], cmake_file, useBytes = TRUE)

  clock_file <- file.path(dest, "src", "platform", "windows", "win_clock.c")
  clock <- readLines(clock_file, warn = FALSE)
  clock_old <- c(
    "int",
    "nni_time_get(uint64_t *seconds, uint32_t *nanoseconds)",
    "{",
    "\tstruct timespec ts;",
    "\tif (timespec_get(&ts, TIME_UTC) == TIME_UTC) {",
    "\t\t*seconds     = ts.tv_sec;",
    "\t\t*nanoseconds = ts.tv_nsec;",
    "\t\treturn (0);",
    "\t}",
    "\treturn (nni_win_error(GetLastError()));",
    "}"
  )
  clock_new <- c(
    "int",
    "nni_time_get(uint64_t *seconds, uint32_t *nanoseconds)",
    "{",
    "\tstruct timespec ts;",
    "#if defined(NNG_HAVE_TIMESPEC_GET)",
    "\tif (timespec_get(&ts, TIME_UTC) == TIME_UTC) {",
    "\t\t*seconds     = ts.tv_sec;",
    "\t\t*nanoseconds = ts.tv_nsec;",
    "\t\treturn (0);",
    "\t}",
    "\treturn (nni_win_error(GetLastError()));",
    "#else",
    "\tFILETIME       ft;",
    "\tULARGE_INTEGER uli;",
    "\tuint64_t       ns100;",
    "\tuint64_t       ns;",
    "",
    "\tGetSystemTimeAsFileTime(&ft);",
    "\tuli.LowPart  = ft.dwLowDateTime;",
    "\tuli.HighPart = ft.dwHighDateTime;",
    "",
    "\t// FILETIME counts 100 ns ticks since 1601-01-01 UTC.",
    "\tns100 = uli.QuadPart - 116444736000000000ULL;",
    "\tns    = ns100 * 100ULL;",
    "",
    "\t*seconds     = ns / 1000000000ULL;",
    "\t*nanoseconds = (uint32_t) (ns % 1000000000ULL);",
    "\treturn (0);",
    "#endif",
    "}"
  )
  clock_text <- paste(clock, collapse = "\n")
  clock_old_text <- paste(clock_old, collapse = "\n")
  if (!grepl(clock_old_text, clock_text, fixed = TRUE)) {
    stop("expected NNG Windows clock implementation in ", clock_file, call. = FALSE)
  }
  writeLines(strsplit(sub(clock_old_text, paste(clock_new, collapse = "\n"), clock_text, fixed = TRUE), "\n", fixed = TRUE)[[1L]], clock_file, useBytes = TRUE)
}

patch_nng_windows_warning_fixes <- function(dest) {
  thread_file <- file.path(dest, "src", "platform", "windows", "win_thread.c")
  thread_text <- paste(readLines(thread_file, warn = FALSE), collapse = "\n")
  replacements <- list(
    c(
      "#include <stdlib.h>",
      paste("#include <stdlib.h>", "#include <string.h>", sep = "\n")
    ),
    c(
      paste(c(
        "void",
        "nni_plat_mtx_fini(nni_plat_mtx *mtx)",
        "{",
        "}"
      ), collapse = "\n"),
      paste(c(
        "void",
        "nni_plat_mtx_fini(nni_plat_mtx *mtx)",
        "{",
        "\tNNI_ARG_UNUSED(mtx);",
        "}"
      ), collapse = "\n")
    ),
    c(
      paste(c(
        "\t\thKernel32 = LoadLibrary(TEXT(\"kernel32.dll\"));",
        "\t\tif (hKernel32 != NULL) {",
        "\t\t\tset_thread_desc =",
        "\t\t\t    (pfnSetThreadDescription) GetProcAddress(",
        "\t\t\t        hKernel32, \"SetThreadDescription\");",
        "\t\t}"
      ), collapse = "\n"),
      paste(c(
        "\t\thKernel32 = LoadLibrary(TEXT(\"kernel32.dll\"));",
        "\t\tif (hKernel32 != NULL) {",
        "\t\t\tFARPROC proc = GetProcAddress(hKernel32, \"SetThreadDescription\");",
        "\t\t\tmemcpy(&set_thread_desc, &proc, sizeof(set_thread_desc));",
        "\t\t}"
      ), collapse = "\n")
    )
  )
  for (pair in replacements) {
    if (!grepl(pair[[1L]], thread_text, fixed = TRUE)) {
      stop("expected NNG Windows warning-fix block in ", thread_file, call. = FALSE)
    }
    thread_text <- sub(pair[[1L]], pair[[2L]], thread_text, fixed = TRUE)
  }
  writeLines(strsplit(thread_text, "\n", fixed = TRUE)[[1L]], thread_file, useBytes = TRUE)

  impl_file <- file.path(dest, "src", "platform", "windows", "win_impl.h")
  impl_text <- paste(readLines(impl_file, warn = FALSE), collapse = "\n")
  impl_old <- paste(c(
    "#define NNI_RWLOCK_INITIALIZER \\",
    "\t{                      \\",
    "\t\tSRWLOCK_INIT   \\",
    "\t}"
  ), collapse = "\n")
  impl_new <- paste(c(
    "#define NNI_RWLOCK_INITIALIZER \\",
    "\t{                      \\",
    "\t\tSRWLOCK_INIT,  \\",
    "\t\tFALSE          \\",
    "\t}"
  ), collapse = "\n")
  if (!grepl(impl_old, impl_text, fixed = TRUE)) {
    stop("expected NNG Windows rwlock initializer in ", impl_file, call. = FALSE)
  }
  writeLines(strsplit(sub(impl_old, impl_new, impl_text, fixed = TRUE), "\n", fixed = TRUE)[[1L]], impl_file, useBytes = TRUE)
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
  if (identical(id, "nng")) {
    patch_nng_cmake(dest)
    patch_nng_windows_rtools_clock(dest)
    patch_nng_windows_warning_fixes(dest)
  }
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
      paste0("      ", json_string("archive_sha256"), ": ", json_string(rec$archive_sha256 %||% ""),
             if (!is.null(rec$extra)) "," else "")
    )
    if (!is.null(rec$extra)) {
      extra_names <- names(rec$extra)
      extra <- vapply(seq_along(rec$extra), function(j) {
        paste0("      ", json_string(extra_names[[j]]), ": ", json_string(rec$extra[[j]]),
               if (j < length(rec$extra)) "," else "")
      }, character(1))
      entry <- c(entry, extra)
    }
    entry <- c(entry, paste0("    }", if (i < length(records)) "," else ""))
    dep_lines <- c(dep_lines, entry)
  }
  lines <- c(lines, dep_lines, "  ]", "}")
  writeLines(lines, file.path(third_party, "versions.json"), useBytes = TRUE)

  md <- c(
    "# Vendored native dependencies",
    "",
    "This directory contains source snapshots compiled into the Rducks DuckDB",
    "extension. Vendored code lives under `third_party/`; Rducks-owned adapter and",
    "shim code lives under `../src/`.",
    "",
    "## Layout",
    "",
    "- `nng/`: NNG 1.11.0 source subset used for native worker transport.",
    "- `mbedtls/`: Mbed TLS 3.6.5 source subset kept for future TLS transport work.",
    "- `patches/`: local patch ledger for edited vendored sources.",
    "- `versions.json`: dependency pins.",
    "",
    "## Pins",
    "",
    sprintf("- NNG `%s` (`%s`):", pins$nng$version, pins$nng$tag),
    sprintf("  <%s>", pins$nng$url),
    sprintf("- Mbed TLS `%s` (`%s`):", pins$mbedtls$version, pins$mbedtls$tag),
    sprintf("  <%s>", pins$mbedtls$url),
    "",
    "## Symbol discipline",
    "",
    "- Keep raw NNG use behind `../src/rducks_nng.c` and Rducks-owned provider",
    "  functions.",
    "",
    "## Refresh commands",
    "",
    "Refresh NNG and Mbed TLS:",
    "",
    "```sh",
    "Rscript tools/vendor_nng_mbedtls.R --force",
    "```",
    "",
    "After any vendor refresh, rebuild and run at least:",
    "",
    "```sh",
    "make test",
    "```",
    "",
    "If vendored NNG files are edited, refresh the matching patch files under",
    "`tools/ext/third_party/patches/nng/` before committing.",
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
