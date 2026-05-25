library(Rducks)

rducks_fake_hanging_worker <- function(endpoint, sleep = 2) {
  suppressPackageStartupMessages(library(Rducks))
  registry <- new.env(parent = emptyenv())
  sock <- NULL
  ctx <- NULL
  on.exit({
    try(if (!is.null(ctx)) close(ctx), silent = TRUE)
    try(if (!is.null(sock)) close(sock), silent = TRUE)
  }, add = TRUE)
  sock <- nanonext::socket("rep", listen = endpoint)
  ctx <- nanonext::context(sock)

  repeat {
    stop_requested <- FALSE
    req_raw <- nanonext::recv(ctx, mode = "raw", block = TRUE)
    if (nanonext::is_error_value(req_raw)) next
    response <- tryCatch({
      req <- Rducks:::rducks_nng_wire_decode_request(req_raw)
      stop_requested <- identical(req$type, Rducks:::rducks_nng_wire_type_stop)
      if (stop_requested || identical(req$type, Rducks:::rducks_nng_wire_type_ping)) {
        Rducks:::rducks_nng_wire_encode_response("ok", raw())
      } else if (identical(req$type, Rducks:::rducks_nng_wire_type_register)) {
        assign(req$udf_id, unserialize(req$payload), envir = registry)
        Rducks:::rducks_nng_wire_encode_response("ok", raw())
      } else if (identical(req$type, Rducks:::rducks_nng_wire_type_execute)) {
        Sys.sleep(sleep)
        Rducks:::rducks_nng_wire_encode_response("error", raw(), "late fake worker response")
      } else {
        stop("unexpected Rducks NNG request type: ", req$type, call. = FALSE)
      }
    }, error = function(e) {
      Rducks:::rducks_nng_wire_encode_response("error", raw(), conditionMessage(e))
    })
    nanonext::send(ctx, response, mode = "raw", block = 1000L)
    if (stop_requested) break
  }
  TRUE
}

rducks_test_batch_contract_transport <- function() {
  transports <- Rducks:::rducks_nng_runtime_transports()
  # This file validates NNG batch and timeout contracts, not transport
  # coverage. Prefer the local IPC transport on CRAN/macbuilder-style
  # machines; random loopback TCP ports can be unavailable or delayed under
  # sandboxed macOS checks before the fake worker has bound its REP socket.
  preferred <- "ipc"
  if (preferred %in% transports) preferred else transports[[1L]]
}

# Cleanup must stay bounded: fake workers intentionally exercise timeout paths,
# and an unconditional collect_mirai() can block forever if the stop request was
# the operation that failed.
rducks_test_mirai_unresolved <- function(task) {
  tryCatch(mirai::unresolved(task), error = function(e) TRUE)
}

rducks_test_stop_fake_worker <- function(endpoint, task, compute, cleanup_paths = character(),
                                        stop_timeout = 2, wait_timeout = 2) {
  try(Rducks:::rducks_nng_transact(
    endpoint,
    Rducks:::rducks_nng_wire_encode_request(Rducks:::rducks_nng_wire_type_stop),
    timeout = stop_timeout,
    retries = 5L
  ), silent = TRUE)

  deadline <- unname(proc.time()[["elapsed"]]) + wait_timeout
  while (isTRUE(rducks_test_mirai_unresolved(task)) &&
         unname(proc.time()[["elapsed"]]) < deadline) {
    Sys.sleep(0.02)
  }
  if (!isTRUE(rducks_test_mirai_unresolved(task))) {
    try(mirai::collect_mirai(task), silent = TRUE)
  }
  try(mirai::daemons(NULL, .compute = compute), silent = TRUE)
  if (is.null(cleanup_paths)) cleanup_paths <- character()
  unlink(cleanup_paths, force = TRUE)
  invisible(NULL)
}

rducks_fake_multibatch_worker <- function(endpoint) {
  suppressPackageStartupMessages({
    library(Rducks)
    library(nanoarrow)
  })
  registry <- new.env(parent = emptyenv())
  sock <- nanonext::socket("rep", listen = endpoint)
  ctx <- nanonext::context(sock)
  on.exit({
    try(close(ctx), silent = TRUE)
    try(close(sock), silent = TRUE)
  }, add = TRUE)

  repeat {
    stop_requested <- FALSE
    req_raw <- nanonext::recv(ctx, mode = "raw", block = TRUE)
    if (nanonext::is_error_value(req_raw)) next

    response <- tryCatch({
      req <- Rducks:::rducks_nng_wire_decode_request(req_raw)
      stop_requested <- identical(req$type, Rducks:::rducks_nng_wire_type_stop)
      if (stop_requested || identical(req$type, Rducks:::rducks_nng_wire_type_ping)) {
        Rducks:::rducks_nng_wire_encode_response("ok", raw())
      } else if (identical(req$type, Rducks:::rducks_nng_wire_type_register)) {
        assign(req$udf_id, unserialize(req$payload), envir = registry)
        Rducks:::rducks_nng_wire_encode_response("ok", raw())
      } else if (identical(req$type, Rducks:::rducks_nng_wire_type_execute)) {
        rec <- get(req$udf_id, envir = registry, inherits = FALSE)
        output_schema <- Rducks:::rducks_arrow_schema_from_spec(rec$output_schema_spec)
        values <- rep(list(42L), req$row_count)
        arr1 <- Rducks:::rducks_arrow_result_array(rec$return_type, values, output_schema, req$row_count)
        arr2 <- Rducks:::rducks_arrow_result_array(rec$return_type, values, output_schema, req$row_count)
        stream <- nanoarrow::basic_array_stream(
          list(arr1, arr2),
          schema = nanoarrow::infer_nanoarrow_schema(arr1)
        )
        con <- rawConnection(raw(), "wb")
        on.exit(try(close(con), silent = TRUE), add = TRUE)
        nanoarrow::write_nanoarrow(stream, con)
        payload <- rawConnectionValue(con)
        close(con)
        Rducks:::rducks_nng_wire_encode_response("ok", payload)
      } else {
        stop("unexpected Rducks NNG request type: ", req$type, call. = FALSE)
      }
    }, error = function(e) {
      Rducks:::rducks_nng_wire_encode_response("error", raw(), conditionMessage(e))
    })

    nanonext::send(ctx, response, mode = "raw", block = 1000L)
    if (stop_requested) break
  }
  TRUE
}

local({
  old_dev <- Sys.getenv("RDUCKS_DEV_SURFACES", unset = NA_character_)
  Sys.setenv(RDUCKS_DEV_SURFACES = "true")
  on.exit({
    if (is.na(old_dev)) Sys.unsetenv("RDUCKS_DEV_SURFACES") else Sys.setenv(RDUCKS_DEV_SURFACES = old_dev)
  }, add = TRUE)

  compute <- paste("rducks-fake-multibatch", Sys.getpid(), sep = "-")
  bundle <- Rducks:::rducks_nng_endpoint_bundle(1L, rducks_test_batch_contract_transport())
  endpoint <- bundle$endpoints[[1L]]
  mirai::daemons(1L, dispatcher = FALSE, .compute = compute)
  task <- mirai::mirai(
    { rducks_fake_multibatch_worker(endpoint) },
    rducks_fake_multibatch_worker = rducks_fake_multibatch_worker,
    endpoint = endpoint,
    .compute = compute
  )
  on.exit({
    rducks_test_stop_fake_worker(
      endpoint, task, compute,
      cleanup_paths = bundle$cleanup_paths,
      stop_timeout = 5,
      wait_timeout = 2
    )
  }, add = TRUE)
  invisible(Rducks:::rducks_nng_transact(
    endpoint,
    Rducks:::rducks_nng_wire_encode_request(Rducks:::rducks_nng_wire_type_ping),
    timeout = 30
  ))

  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
  on.exit({
    try(rducks_release(con), silent = TRUE)
    try(Rducks:::rducks_nng_stop_all_providers(quiet = TRUE), silent = TRUE)
    DBI::dbDisconnect(con, shutdown = TRUE)
  }, add = TRUE)
  rducks_enable(con, threads = "single")
  plan <- rducks_execution_plan(
    "arrow_ipc", "multiprocess_parallel",
    ipc_endpoints = endpoint,
    ipc_workers = 1L,
    ipc_timeout = 30
  )
  rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
  invisible(rducks_register_scalar_udf(
    con, "rducks_multibatch_result",
    function(x) x + 1L,
    INTEGER, INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  ))
  expect_error(
    DBI::dbGetQuery(con, "SELECT rducks_multibatch_result(1::INTEGER) AS x"),
    "RIPC result payload contained more than one record batch"
  )
})

local({
  old_dev <- Sys.getenv("RDUCKS_DEV_SURFACES", unset = NA_character_)
  Sys.setenv(RDUCKS_DEV_SURFACES = "true")
  on.exit({
    if (is.na(old_dev)) Sys.unsetenv("RDUCKS_DEV_SURFACES") else Sys.setenv(RDUCKS_DEV_SURFACES = old_dev)
  }, add = TRUE)

  compute <- paste("rducks-fake-hanging", Sys.getpid(), sep = "-")
  bundle <- Rducks:::rducks_nng_endpoint_bundle(1L, rducks_test_batch_contract_transport())
  endpoint <- bundle$endpoints[[1L]]
  mirai::daemons(1L, dispatcher = FALSE, .compute = compute)
  task <- mirai::mirai(
    { rducks_fake_hanging_worker(endpoint, sleep = 1.5) },
    rducks_fake_hanging_worker = rducks_fake_hanging_worker,
    endpoint = endpoint,
    .compute = compute
  )
  on.exit({
    rducks_test_stop_fake_worker(
      endpoint, task, compute,
      cleanup_paths = bundle$cleanup_paths,
      stop_timeout = 2,
      wait_timeout = 2
    )
  }, add = TRUE)
  invisible(Rducks:::rducks_nng_transact(
    endpoint,
    Rducks:::rducks_nng_wire_encode_request(Rducks:::rducks_nng_wire_type_ping),
    timeout = 30
  ))

  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
  on.exit({
    try(rducks_release(con), silent = TRUE)
    DBI::dbDisconnect(con, shutdown = TRUE)
  }, add = TRUE)
  rducks_enable(con, threads = "single")
  plan <- rducks_execution_plan(
    "arrow_ipc", "multiprocess_parallel",
    ipc_endpoints = endpoint,
    ipc_workers = 1L,
    ipc_timeout = 0.25
  )
  rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
  invisible(rducks_register_scalar_udf(
    con, "rducks_hanging_worker_timeout",
    function(x) x + 1L,
    INTEGER, INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  ))
  elapsed <- system.time(expect_error(
    DBI::dbGetQuery(con, "SELECT rducks_hanging_worker_timeout(1::INTEGER) AS x"),
    "nng_recvmsg failed|[Tt]imed out"
  ))[["elapsed"]]
  expect_true(elapsed < 5)
})
