#!/usr/bin/env Rscript
args <- commandArgs(trailingOnly = TRUE)

`%||%` <- function(x, y) if (is.null(x)) y else x

parse_args <- function(args) {
  out <- list()
  i <- 1L
  while (i <= length(args)) {
    key <- args[[i]]
    if (startsWith(key, "--") && i + 1L <= length(args)) {
      out[[substring(key, 3L)]] <- args[[i + 1L]]
      i <- i + 2L
    } else {
      i <- i + 1L
    }
  }
  out
}

start_signature <- function() {
  c(as.raw(c(0, 147, 4, 16)), charToRaw("duckdb_signature"), as.raw(c(128, 4)))
}

padded_byte_string <- function(x) {
  bytes <- charToRaw(x)
  if (length(bytes) > 32L) {
    stop("metadata field too long: ", x, call. = FALSE)
  }
  c(bytes, as.raw(rep(0, 32L - length(bytes))))
}

opts <- parse_args(args)
required <- c("library-file", "out-file", "extension-name", "duckdb-platform", "duckdb-version", "extension-version")
missing <- required[!nzchar(vapply(required, function(x) opts[[x]] %||% "", character(1)))]
if (length(missing)) {
  stop("missing required arguments: ", paste(missing, collapse = ", "), call. = FALSE)
}
# tools/duckdb_capi_abi.sh chooses the ABI per engine release. The version
# field holds the engine version for C_STRUCT_UNSTABLE and the pinned V1 C API
# version for C_STRUCT.
abi_type <- opts[["abi-type"]] %||% "C_STRUCT_UNSTABLE"
if (!abi_type %in% c("C_STRUCT_UNSTABLE", "C_STRUCT")) {
  stop("Rducks extension metadata ABI must be C_STRUCT_UNSTABLE or C_STRUCT, not ", abi_type, call. = FALSE)
}
if (identical(abi_type, "C_STRUCT") && !grepl("^v1\\.[0-9]+\\.[0-9]+$", opts[["duckdb-version"]])) {
  stop("a C_STRUCT footer must record a V1 C API version such as v1.5.6, not ",
       opts[["duckdb-version"]], call. = FALSE)
}
out_tmp <- paste0(opts[["out-file"]], ".tmp")
invisible(file.copy(opts[["library-file"]], out_tmp, overwrite = TRUE))
con <- file(out_tmp, open = "ab")
on.exit(close(con), add = TRUE)
writeBin(start_signature(), con, useBytes = TRUE)
writeBin(padded_byte_string(""), con, useBytes = TRUE)
writeBin(padded_byte_string(""), con, useBytes = TRUE)
writeBin(padded_byte_string(""), con, useBytes = TRUE)
writeBin(padded_byte_string(abi_type), con, useBytes = TRUE)
writeBin(padded_byte_string(opts[["extension-version"]]), con, useBytes = TRUE)
writeBin(padded_byte_string(opts[["duckdb-version"]]), con, useBytes = TRUE)
writeBin(padded_byte_string(opts[["duckdb-platform"]]), con, useBytes = TRUE)
writeBin(padded_byte_string("4"), con, useBytes = TRUE)
writeBin(as.raw(rep(0, 256)), con, useBytes = TRUE)
close(con)
invisible(file.rename(out_tmp, opts[["out-file"]]))
