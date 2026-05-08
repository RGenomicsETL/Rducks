#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(Rducks)
  library(nanoarrow)
})

# Local diagnostic benchmark for the native NNG provider path. Rducks starts
# worker loops with mirai daemons; chunk payloads are owned Arrow IPC bytes.
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

new_nng_provider <- function() {
  provider <- Rducks:::rducks_nng_provider(workers = 1L)
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
  warm_req <- Rducks:::rducks_nng_wire_encode_request(
    Rducks:::rducks_nng_wire_type_execute, "plus_one", row_count, input_payload
  )
  warm <- Rducks:::rducks_nng_transact(provider$endpoints()[[1L]], warm_req, timeout = 30)
  decoded <- Rducks:::rducks_nng_wire_decode_response(warm)
  if (!identical(decoded$status, "ok")) stop(decoded$error, call. = FALSE)
  provider
}

run_nng_reqrep <- function() {
  provider <- new_nng_provider()
  on.exit(provider$stop(), add = TRUE)
  endpoint <- provider$endpoints()[[1L]]
  system.time({
    for (i in seq_len(task_count)) {
      req <- Rducks:::rducks_nng_wire_encode_request(
        Rducks:::rducks_nng_wire_type_execute, "plus_one", row_count, input_payload
      )
      resp <- Rducks:::rducks_nng_transact(endpoint, req, timeout = 30)
      decoded <- Rducks:::rducks_nng_wire_decode_response(resp)
      if (!identical(decoded$status, "ok")) stop(decoded$error, call. = FALSE)
    }
  })[["elapsed"]]
}

one_iteration <- function(i) {
  data.frame(
    iteration = i,
    provider_path = "ipc_nng_pool_reqrep",
    elapsed_seconds = run_nng_reqrep(),
    stringsAsFactors = FALSE
  )
}

runs <- do.call(rbind, lapply(seq_len(iterations), one_iteration))
print(runs, row.names = FALSE)
summary <- aggregate(elapsed_seconds ~ provider_path, runs, median)
print(summary, row.names = FALSE)
