library(Rducks)

rducks_nng_transport_trace <- function(phase) {
  message("[rducks-nng-transport] ", phase)
}

local({
  old_dev <- Sys.getenv("RDUCKS_DEV_SURFACES", unset = NA_character_)
  Sys.setenv(RDUCKS_DEV_SURFACES = "true")
  on.exit({
    if (is.na(old_dev)) Sys.unsetenv("RDUCKS_DEV_SURFACES") else Sys.setenv(RDUCKS_DEV_SURFACES = old_dev)
  }, add = TRUE)

  rducks_nng_transport_trace("diagnostic-connect:start")
  con0 <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con0, shutdown = TRUE), add = TRUE)
  rducks_enable(con0)
  enabled <- DBI::dbGetQuery(con0, "SELECT rducks_nng_enabled() AS enabled")$enabled[[1L]]
  expect_true(enabled)
  expect_true(DBI::dbGetQuery(con0, "SELECT rducks_nng_self_test() AS ok")$ok[[1L]])
  rducks_release(con0)
  rducks_nng_transport_trace("diagnostic-connect:done")

  transports <- Rducks:::rducks_nng_runtime_transports()
  if (identical(Sys.info()[["sysname"]], "Windows")) {
    expect_false("ws" %in% transports)
  } else {
    expect_true(all(c("ipc", "tcp", "ws") %in% transports))
  }
  if (identical(Sys.info()[["sysname"]], "Linux")) {
    expect_true("abstract" %in% transports)
  } else {
    expect_false("abstract" %in% transports)
  }
  if (identical(Sys.info()[["sysname"]], "Windows")) {
    expect_false("unix" %in% transports)
  } else {
    expect_true("unix" %in% transports)
  }
  ipc_workers <- suppressWarnings(as.integer(Sys.getenv("RDUCKS_TEST_IPC_WORKERS", "1")))
  if (length(ipc_workers) != 1L || is.na(ipc_workers) || ipc_workers < 1L) ipc_workers <- 1L

  for (transport in transports) {
    local({
      transport <- transport
      rducks_nng_transport_trace(paste0("transport:", transport, ":connect:start"))
      con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
      on.exit({
        rducks_nng_transport_trace(paste0("transport:", transport, ":cleanup:release:start"))
        try(rducks_release(con), silent = TRUE)
        rducks_nng_transport_trace(paste0("transport:", transport, ":cleanup:release:done"))
        rducks_nng_transport_trace(paste0("transport:", transport, ":cleanup:stop-providers:start"))
        try(Rducks:::rducks_nng_stop_all_providers(quiet = TRUE), silent = TRUE)
        rducks_nng_transport_trace(paste0("transport:", transport, ":cleanup:stop-providers:done"))
        rducks_nng_transport_trace(paste0("transport:", transport, ":cleanup:disconnect:start"))
        DBI::dbDisconnect(con, shutdown = TRUE)
        rducks_nng_transport_trace(paste0("transport:", transport, ":cleanup:disconnect:done"))
      }, add = TRUE)
      rducks_enable(con)
      rducks_nng_transport_trace(paste0("transport:", transport, ":connect:done"))

      rducks_nng_transport_trace(paste0("transport:", transport, ":plan:start"))
      plan <- rducks_execution_plan(
        "arrow_ipc", "multiprocess_parallel",
        ipc_transport = transport,
        ipc_workers = ipc_workers,
        ipc_timeout = 10
      )
      expect_equal(plan$ipc_options$transport, transport)
      rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
      rducks_nng_transport_trace(paste0("transport:", transport, ":plan:done"))
      name <- paste0("nng_transport_", gsub("[^[:alnum:]]+", "_", transport))
      rducks_nng_transport_trace(paste0("transport:", transport, ":register:start"))
      reg <- rducks_register_scalar_udf(
        con, name,
        function(x) x + 1L,
        INTEGER, INTEGER,
        mode = "vectorized",
        side_effects = TRUE
      )
      rducks_nng_transport_trace(paste0("transport:", transport, ":register:done"))
      expect_equal(reg$execution_plan$plan_id, "arrow_ipc+multiprocess_parallel")
      rducks_nng_transport_trace(paste0("transport:", transport, ":query:start"))
      result <- DBI::dbGetQuery(con, sprintf(
        "SELECT %s(i::INTEGER) AS x FROM range(4) t(i)",
        DBI::dbQuoteIdentifier(con, name)
      ))
      rducks_nng_transport_trace(paste0("transport:", transport, ":query:done"))
      expect_equal(result$x, 1:4)
      rducks_nng_transport_trace(paste0("transport:", transport, ":explain:start"))
      info <- rducks_explain_udf(con, name)
      rducks_nng_transport_trace(paste0("transport:", transport, ":explain:done"))
      expect_equal(info$native_marshalling, "arrow_ipc")
      expect_equal(info$evaluator, "RIPC")
      expect_true(info$arrow_ipc_chunks >= 1)
      rducks_nng_transport_trace(paste0("transport:", transport, ":stats:start"))
      stats <- Rducks:::rducks_nng_provider_for_runtime(
        runtime_token = Rducks:::rducks_runtime_token(con),
        workers = ipc_workers,
        max_pending = 64L,
        endpoints = NULL,
        transport = transport
      )$stats()
      rducks_nng_transport_trace(paste0("transport:", transport, ":stats:done"))
      expect_equal(stats$transport, transport)
      expect_equal(stats$workers, ipc_workers)
      rducks_nng_transport_trace(paste0("transport:", transport, ":done"))
    })
  }
})
