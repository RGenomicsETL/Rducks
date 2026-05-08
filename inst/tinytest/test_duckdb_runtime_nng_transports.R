library(Rducks)

local({
  Sys.setenv(RDUCKS_DEV_SURFACES = "true")
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit({
    try(Rducks:::rducks_nng_stop_all_providers(), silent = TRUE)
    DBI::dbDisconnect(con, shutdown = TRUE)
  }, add = TRUE)
  rducks_enable(con)

  enabled <- DBI::dbGetQuery(con, "SELECT rducks_nng_enabled() AS enabled")$enabled[[1L]]
  if (isTRUE(enabled)) {
    expect_true(DBI::dbGetQuery(con, "SELECT rducks_nng_self_test() AS ok")$ok[[1L]])

    transports <- Rducks:::rducks_nng_supported_transports()
    if (!identical(Sys.info()[["sysname"]], "Linux")) {
      transports <- setdiff(transports, "abstract")
    }

    for (transport in transports) {
      Rducks:::rducks_nng_stop_all_providers()
      plan <- rducks_execution_plan(
        "arrow_ipc", "multiprocess_parallel",
        ipc_transport = transport,
        ipc_workers = 1L,
        ipc_timeout = 30
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
        workers = 1L,
        max_pending = 64L,
        endpoints = NULL,
        transport = transport
      )$stats()
      expect_equal(stats$transport, transport)
    }
  } else {
    expect_false(enabled)
  }
})
