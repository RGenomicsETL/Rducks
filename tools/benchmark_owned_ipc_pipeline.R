#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(Rducks)
  library(nanoarrow)
})

# Local diagnostic benchmark for owned Arrow IPC payload evaluation. This uses
# the same R worker evaluator as the NNG worker loop without Future scheduling.
n <- 8192L
chunk_size <- 1024L
sleep_s <- 0.1
iterations <- 3L

mk_input_payload <- function(x) {
  array <- nanoarrow::as_nanoarrow_array(data.frame(arg1 = as.integer(x)))
  Rducks:::rducks_arrow_ipc_encode(array)
}

output_schema_spec <- Rducks:::rducks_arrow_schema_to_spec(
  nanoarrow::infer_nanoarrow_schema(data.frame(result = integer()))
)

rows <- 0:(n - 1L)
chunk_id <- ceiling(seq_along(rows) / chunk_size)
chunks <- split(rows, chunk_id)
payloads <- lapply(chunks, mk_input_payload)
ns <- lengths(chunks)

fun <- local({
  delay <- sleep_s
  function(x) {
    Sys.sleep(delay)
    x + 1L
  }
})
arg_types <- list(INTEGER)
return_type <- INTEGER

worker_eval <- function(payload, n_rows) {
  Rducks:::rducks_ipc_worker_eval_arrow_ipc_chunk(
    input_payload = payload,
    output_schema_spec = output_schema_spec,
    n = n_rows,
    fun = fun,
    arg_types = arg_types,
    return_type = return_type,
    null_handling = "default",
    exception_handling = "rethrow",
    mode = "vectorized"
  )
}

payload_values <- function(result_payloads) {
  unlist(lapply(result_payloads, function(payload) {
    decoded <- Rducks:::rducks_arrow_ipc_decode_array(payload)
    as.data.frame(decoded$array)[[1L]]
  }), use.names = FALSE)
}

validate_result <- function(label, result_payloads) {
  values <- as.integer(payload_values(result_payloads))
  expected <- as.integer(rows + 1L)
  if (!identical(values, expected)) {
    stop(label, " produced incorrect results", call. = FALSE)
  }
  invisible(result_payloads)
}

run_sequential <- function() {
  Map(worker_eval, payloads, ns)
}

time_run <- function(label, expr) {
  gc()
  value <- NULL
  elapsed <- system.time({ value <- force(expr) })[["elapsed"]]
  validate_result(label, value)
  data.frame(expression = label, elapsed = elapsed, stringsAsFactors = FALSE)
}

timings <- do.call(rbind, lapply(seq_len(iterations), function(i) {
  cbind(iteration = i, time_run("sequential_owned_arrow_ipc", run_sequential()))
}))
print(timings, row.names = FALSE)

median_elapsed <- tapply(timings$elapsed, timings$expression, median)
cat(sprintf(
  "owned_arrow_ipc_pipeline rows=%d chunks=%d chunk_size=%d sleep=%.3f median_sequential=%.3fs\n",
  n, length(chunks), chunk_size, sleep_s, median_elapsed[["sequential_owned_arrow_ipc"]]
))
