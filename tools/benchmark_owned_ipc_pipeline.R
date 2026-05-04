#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(Rducks)
  library(bench)
  library(future)
  library(future.mirai)
  library(nanoarrow)
})

int_env <- function(name, default) {
  value <- suppressWarnings(as.integer(Sys.getenv(name, as.character(default))))
  if (length(value) != 1L || is.na(value) || value < 1L) default else value
}
num_env <- function(name, default) {
  value <- suppressWarnings(as.numeric(Sys.getenv(name, as.character(default))))
  if (length(value) != 1L || is.na(value) || value < 0) default else value
}

n <- int_env("RDUCKS_OWNED_PIPELINE_N", 8192L)
chunk_size <- int_env("RDUCKS_OWNED_PIPELINE_CHUNK_SIZE", 1024L)
workers <- int_env("RDUCKS_OWNED_PIPELINE_WORKERS", 4L)
sleep_s <- num_env("RDUCKS_OWNED_PIPELINE_SLEEP", 0.1)
iterations <- int_env("RDUCKS_OWNED_PIPELINE_ITERATIONS", 3L)
# Benchmark-only Future polling tweak: small worker tasks can finish before
# the default polling interval notices them. This reduces wait latency; it is
# not required for Rducks correctness or for real parallelism.
options(future.wait.interval = 0.001, future.wait.alpha = 1.01)
future::plan(future.mirai::mirai_multisession, workers = workers)
# Warm workers so the measurement reflects chunk scheduling, not startup.
invisible(future::value(future::future(NULL)))

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

fun <- function(x) {
  Sys.sleep(sleep_s)
  x + 1L
}

worker_eval <- function(payload, n_rows) {
  Rducks:::rducks_future_worker_eval_arrow_ipc_chunk(
    input_payload = payload,
    output_schema_spec = output_schema_spec,
    n = n_rows,
    fun = fun,
    arg_types = list(INTEGER),
    return_type = INTEGER,
    null_handling = "default",
    exception_handling = "rethrow",
    mode = "vectorized"
  )
}

bench_result <- bench::mark(
  sequential = {
    seq_payloads <- Map(worker_eval, payloads, ns)
    invisible(seq_payloads)
  },
  parallel = {
    futures <- Map(function(payload, n_rows) {
      future::future(
        worker_eval(payload, n_rows),
        globals = list(worker_eval = worker_eval, payload = payload, n_rows = n_rows),
        packages = "Rducks",
        stdout = FALSE
      )
    }, payloads, ns)
    par_payloads <- future::value(futures, stdout = FALSE, signal = FALSE)
    invisible(par_payloads)
  },
  iterations = iterations,
  check = FALSE
)

print(bench_result[, c("expression", "median", "itr/sec", "mem_alloc", "n_itr", "n_gc")])

median_seconds <- setNames(as.numeric(bench_result$median), as.character(bench_result$expression))
cat(sprintf(
  "owned_arrow_ipc_pipeline provider=future.mirai workers=%d rows=%d chunks=%d chunk_size=%d sleep=%.3f median_speedup=%.2fx\n",
  workers, n, length(chunks), chunk_size, sleep_s,
  median_seconds[["sequential"]] / median_seconds[["parallel"]]
))
