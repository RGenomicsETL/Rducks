#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(Rducks)
  library(future)
  library(nanoarrow)
})

if (!requireNamespace("mirai", quietly = TRUE)) {
  stop("benchmark_ipc_providers.R requires the mirai package", call. = FALSE)
}
if (!requireNamespace("future.mirai", quietly = TRUE)) {
  stop("benchmark_ipc_providers.R requires the future.mirai package", call. = FALSE)
}

task_count <- 50L
row_count <- 64L
iterations <- 3L

input_payload <- Rducks:::rducks_arrow_ipc_encode(
  nanoarrow::as_nanoarrow_array(data.frame(arg1 = seq_len(row_count)))
)
output_schema_spec <- Rducks:::rducks_arrow_schema_to_spec(
  nanoarrow::infer_nanoarrow_schema(data.frame(result = integer()))
)
fun <- function(x) x + 1L

old_plan <- future::plan()
on.exit(future::plan(old_plan), add = TRUE)

make_future_engine <- function() {
  plan <- rducks_execution_plan("arrow_ipc", "multiprocess_parallel", future_timeout = 60)
  state <- Rducks:::rducks_future_precompute_worker_globals(fun, plan$future_options$globals)
  list(
    plan = plan,
    fun = fun,
    arg_types = list(INTEGER),
    return_type = INTEGER,
    null_handling = "default",
    exception_handling = "rethrow",
    mode = "vectorized",
    future_globals = state$globals,
    future_packages = state$packages
  )
}

run_future <- function(strategy) {
  if (identical(strategy, "future.mirai")) {
    future::plan(future.mirai::mirai_multisession, workers = 1)
  } else {
    future::plan(future::multisession, workers = 1)
  }
  engine <- make_future_engine()
  invisible(Rducks:::rducks_future_submit_vectorized_chunk(
    engine, input_payload, output_schema_spec, row_count
  ))
  system.time({
    for (i in seq_len(task_count)) {
      invisible(Rducks:::rducks_future_submit_vectorized_chunk(
        engine, input_payload, output_schema_spec, row_count
      ))
    }
  })[["elapsed"]]
}

new_mirai_provider <- function() {
  provider <- Rducks:::rducks_mirai_provider(workers = 1L)
  provider$start()
  provider$register_udf(
    udf_id = "plus_one",
    udf_name = "plus_one",
    fun = fun,
    arg_types = list(INTEGER),
    return_type = INTEGER,
    mode = "vectorized",
    null_handling = "default",
    exception_handling = "rethrow",
    output_schema_spec = output_schema_spec
  )
  warm <- provider$submit("plus_one", "warm", row_count, input_payload)
  invisible(provider$collect_many(warm))
  provider
}

run_mirai_sequential <- function() {
  provider <- new_mirai_provider()
  on.exit(provider$stop(), add = TRUE)
  system.time({
    for (i in seq_len(task_count)) {
      id <- provider$submit("plus_one", paste0("chunk-", i), row_count, input_payload)
      invisible(provider$collect_many(id))
    }
  })[["elapsed"]]
}

run_mirai_batched <- function() {
  provider <- new_mirai_provider()
  on.exit(provider$stop(), add = TRUE)
  system.time({
    ids <- vapply(seq_len(task_count), function(i) {
      provider$submit("plus_one", paste0("chunk-", i), row_count, input_payload)
    }, character(1))
    invisible(provider$collect_many(ids))
  })[["elapsed"]]
}

one_iteration <- function(i) {
  data.frame(
    iteration = i,
    provider_path = c(
      "future_multisession",
      "future_mirai_multisession",
      "ipc_mirai_pool_sequential",
      "ipc_mirai_pool_batched"
    ),
    elapsed_seconds = c(
      run_future("multisession"),
      run_future("future.mirai"),
      run_mirai_sequential(),
      run_mirai_batched()
    ),
    stringsAsFactors = FALSE
  )
}

runs <- do.call(rbind, lapply(seq_len(iterations), one_iteration))
print(runs, row.names = FALSE)
summary <- aggregate(elapsed_seconds ~ provider_path, runs, median)
summary$relative_to_future_multisession <-
  summary$elapsed_seconds[summary$provider_path == "future_multisession"] / summary$elapsed_seconds
summary <- summary[match(
  c("future_multisession", "future_mirai_multisession", "ipc_mirai_pool_sequential", "ipc_mirai_pool_batched"),
  summary$provider_path
), ]
print(summary, row.names = FALSE)
