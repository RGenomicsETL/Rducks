rducks_nng_transports_body <- function(transports = NULL) {
  old_dev <- Sys.getenv("RDUCKS_DEV_SURFACES", unset = NA_character_)
  Sys.setenv(RDUCKS_DEV_SURFACES = "true")
  on.exit({
    if (is.na(old_dev)) Sys.unsetenv("RDUCKS_DEV_SURFACES") else Sys.setenv(RDUCKS_DEV_SURFACES = old_dev)
  }, add = TRUE)
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit({
    try(Rducks:::rducks_nng_stop_all_providers(quiet = TRUE), silent = TRUE)
    DBI::dbDisconnect(con, shutdown = TRUE)
  }, add = TRUE)
  rducks_enable(con)

  enabled <- DBI::dbGetQuery(con, "SELECT rducks_nng_enabled() AS enabled")$enabled[[1L]]
  expect_true(enabled)
  expect_true(DBI::dbGetQuery(con, "SELECT rducks_nng_self_test() AS ok")$ok[[1L]])

  available_transports <- Rducks:::rducks_nng_runtime_transports()
  expect_true(all(c("ipc", "tcp", "ws") %in% available_transports))
  if (identical(Sys.info()[["sysname"]], "Linux")) {
    expect_true("abstract" %in% available_transports)
  } else {
    expect_false("abstract" %in% available_transports)
  }
  if (identical(Sys.info()[["sysname"]], "Windows")) {
    expect_false("unix" %in% available_transports)
  } else {
    expect_true("unix" %in% available_transports)
  }

  if (is.null(transports)) {
    transports <- available_transports
  } else {
    expect_true(all(transports %in% available_transports))
  }

  ipc_workers <- suppressWarnings(as.integer(Sys.getenv("RDUCKS_TEST_IPC_WORKERS", "1")))
  if (length(ipc_workers) != 1L || is.na(ipc_workers) || ipc_workers < 1L) ipc_workers <- 1L

  for (transport in transports) {
    Rducks:::rducks_nng_stop_all_providers(quiet = TRUE)
    plan <- rducks_execution_plan(
      "arrow_ipc", "multiprocess_parallel",
      ipc_transport = transport,
      ipc_workers = ipc_workers,
      ipc_timeout = 10
    )
    expect_equal(plan$ipc_options$transport, transport)
    rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
    name <- paste0("nng_transport_", gsub("[^[:alnum:]]+", "_", transport))
    reg <- rducks_register(
      con, name,
      function(x) x + 1L,
      INTEGER, INTEGER,
      mode = "vectorized",
      side_effects = TRUE
    )
    expect_equal(reg$execution_plan$plan_id, "arrow_ipc+multiprocess_parallel")
    result <- DBI::dbGetQuery(con, sprintf(
      "SELECT %s(i::INTEGER) AS x FROM range(4) t(i)",
      DBI::dbQuoteIdentifier(con, name)
    ))
    expect_equal(result$x, 1:4)
    info <- rducks_explain_udf(con, name)
    expect_equal(info$native_marshalling, "arrow_ipc")
    expect_equal(info$evaluator, "RIPC")
    expect_true(info$arrow_ipc_chunks >= 1)
    stats <- Rducks:::rducks_nng_provider_for_runtime(
      runtime_token = Rducks:::rducks_runtime_token(con),
      workers = ipc_workers,
      max_pending = 64L,
      endpoints = NULL,
      transport = transport
    )$stats()
    expect_equal(stats$transport, transport)
    expect_equal(stats$workers, ipc_workers)
  }
}
