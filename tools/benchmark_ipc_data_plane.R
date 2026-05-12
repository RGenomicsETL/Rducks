#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(Rducks)
  library(nanoarrow)
})

# Diagnostic benchmark for issue #11 shared-memory data-plane design.
# It measures today's owned Arrow IPC byte path and, when mori is installed,
# the per-chunk cost/serialized size of creating mori shared references. This is
# intentionally not a package API and does not enable shared-memory chunk IO.

parse_options <- function(args) {
  out <- list(rows = "1024,8192", reps = "3")
  for (arg in args) {
    if (!grepl("^--", arg)) next
    parts <- strsplit(sub("^--", "", arg), "=", fixed = TRUE)[[1L]]
    key <- parts[[1L]]
    value <- if (length(parts) > 1L) paste(parts[-1L], collapse = "=") else "true"
    out[[key]] <- value
  }
  out
}

opts <- parse_options(commandArgs(trailingOnly = TRUE))
rows <- as.integer(strsplit(opts$rows, ",", fixed = TRUE)[[1L]])
rows <- rows[is.finite(rows) & rows > 0L]
reps <- as.integer(opts$reps)
if (!length(rows)) stop("--rows must contain at least one positive integer", call. = FALSE)
if (length(reps) != 1L || is.na(reps) || reps < 1L) stop("--reps must be a positive integer", call. = FALSE)

make_frame <- function(n) {
  data.frame(
    i = seq_len(n),
    x = as.numeric(seq_len(n)) / 10,
    label = sprintf("row-%06d", seq_len(n)),
    stringsAsFactors = FALSE
  )
}

time_value <- function(expr) {
  value <- NULL
  elapsed <- system.time({ value <- force(expr) })[["elapsed"]]
  list(value = value, elapsed = elapsed)
}

bench_arrow_ipc <- function(frame, row_count, rep) {
  array <- nanoarrow::as_nanoarrow_array(frame)
  encoded <- time_value(Rducks:::rducks_arrow_ipc_encode(array))
  payload <- encoded$value

  wire <- time_value({
    request <- Rducks:::rducks_nng_wire_encode_request(
      Rducks:::rducks_nng_wire_type_execute,
      udf_id = "benchmark",
      row_count = row_count,
      payload = payload
    )
    decoded <- Rducks:::rducks_nng_wire_decode_request(request)
    stopifnot(identical(decoded$payload, payload), identical(decoded$row_count, as.integer(row_count)))
    request
  })

  decoded <- time_value({
    decoded <- Rducks:::rducks_arrow_ipc_decode_array(payload)
    materialized <- as.data.frame(decoded$array)
    stopifnot(identical(nrow(materialized), as.integer(row_count)))
    materialized
  })

  data.frame(
    rows = row_count,
    rep = rep,
    path = c("arrow_ipc_encode", "nng_wire_copy", "arrow_ipc_decode"),
    elapsed_seconds = c(encoded$elapsed, wire$elapsed, decoded$elapsed),
    payload_bytes = c(length(payload), length(wire$value), length(payload)),
    serialized_bytes = NA_integer_,
    stringsAsFactors = FALSE
  )
}

bench_mori_candidate <- function(frame, row_count, rep) {
  if (!requireNamespace("mori", quietly = TRUE)) {
    return(data.frame(
      rows = row_count,
      rep = rep,
      path = "mori_per_chunk_unavailable",
      elapsed_seconds = NA_real_,
      payload_bytes = NA_integer_,
      serialized_bytes = NA_integer_,
      stringsAsFactors = FALSE
    ))
  }

  shared <- time_value(mori::share(frame))
  serialized <- time_value(serialize(shared$value, NULL, xdr = FALSE))
  restored <- time_value({
    value <- unserialize(serialized$value)
    stopifnot(identical(nrow(as.data.frame(value)), as.integer(row_count)))
    value
  })

  data.frame(
    rows = row_count,
    rep = rep,
    path = c("mori_share_frame", "mori_serialize_ref", "mori_unserialize_ref"),
    elapsed_seconds = c(shared$elapsed, serialized$elapsed, restored$elapsed),
    payload_bytes = NA_integer_,
    serialized_bytes = c(NA_integer_, length(serialized$value), length(serialized$value)),
    stringsAsFactors = FALSE
  )
}

results <- do.call(rbind, lapply(rows, function(n) {
  frame <- make_frame(n)
  do.call(rbind, lapply(seq_len(reps), function(rep) {
    rbind(
      bench_arrow_ipc(frame, n, rep),
      bench_mori_candidate(frame, n, rep)
    )
  }))
}))

print(results, row.names = FALSE)

summary <- aggregate(
  elapsed_seconds ~ rows + path,
  results,
  function(x) median(x, na.rm = TRUE)
)
names(summary)[[3L]] <- "median_elapsed_seconds"
print(summary, row.names = FALSE)
