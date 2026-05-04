#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(Rducks)
  library(future)
  library(future.mirai)
  library(nanoarrow)
})

# Benchmark parameters are explicit script constants, not hidden environment
# variables. Edit them here when running a different local experiment.
n <- 8192L
chunk_size <- 1024L
workers <- 4L
sleep_s <- 0.1
iterations <- 3L
# Benchmark-only Future polling tweak: small worker tasks can finish before
# the default polling interval notices them. This reduces wait latency; it is
# not required for Rducks correctness or for real parallelism.
options(future.wait.interval = 0.001, future.wait.alpha = 1.01)
future::plan(future.mirai::mirai_multisession, workers = workers)
# Warm workers so the measurement reflects chunk scheduling, not startup.
warmup <- lapply(seq_len(workers), function(i) future::future(NULL))
invisible(future::value(warmup, stdout = FALSE, signal = FALSE))

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

worker_eval <- function(payload, n_rows, output_schema_spec, fun, arg_types, return_type) {
  Rducks:::rducks_future_worker_eval_arrow_ipc_chunk(
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

stop_if_worker_error <- function(values) {
  failed <- vapply(values, inherits, logical(1), "error")
  if (any(failed)) {
    stop("owned IPC worker failed: ", conditionMessage(values[[which(failed)[1L]]]), call. = FALSE)
  }
  values
}

run_sequential <- function() {
  Map(worker_eval, payloads, ns,
    MoreArgs = list(
      output_schema_spec = output_schema_spec,
      fun = fun,
      arg_types = arg_types,
      return_type = return_type
    )
  )
}

run_parallel <- function() {
  futures <- Map(function(payload, n_rows) {
    future::future(
      worker_eval(payload, n_rows, output_schema_spec, fun, arg_types, return_type),
      globals = list(
        worker_eval = worker_eval,
        payload = payload,
        n_rows = n_rows,
        output_schema_spec = output_schema_spec,
        fun = fun,
        arg_types = arg_types,
        return_type = return_type
      ),
      packages = "Rducks",
      stdout = FALSE
    )
  }, payloads, ns)
  stop_if_worker_error(future::value(futures, stdout = FALSE, signal = FALSE))
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

time_run <- function(label, expr) {
  gc()
  value <- NULL
  elapsed <- system.time({
    value <- force(expr)
  })[["elapsed"]]
  validate_result(label, value)
  data.frame(expression = label, elapsed = elapsed, stringsAsFactors = FALSE)
}

timings <- do.call(rbind, lapply(seq_len(iterations), function(i) {
  rbind(
    cbind(iteration = i, time_run("sequential", run_sequential())),
    cbind(iteration = i, time_run("parallel", run_parallel()))
  )
}))
print(timings, row.names = FALSE)

median_elapsed <- tapply(timings$elapsed, timings$expression, median)
cat(sprintf(
  "owned_arrow_ipc_pipeline provider=future.mirai workers=%d rows=%d chunks=%d chunk_size=%d sleep=%.3f median_sequential=%.3fs median_parallel=%.3fs median_speedup=%.2fx\n",
  workers, n, length(chunks), chunk_size, sleep_s,
  median_elapsed[["sequential"]], median_elapsed[["parallel"]],
  median_elapsed[["sequential"]] / median_elapsed[["parallel"]]
))
