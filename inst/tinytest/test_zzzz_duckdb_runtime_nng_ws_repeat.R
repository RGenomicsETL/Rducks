library(Rducks)

repeat_enabled <- tolower(Sys.getenv("RDUCKS_TEST_NNG_WS_REPEAT", Sys.getenv("RDUCKS_TEST_WS_REPEAT", "0"))) %in% c("1", "true", "yes")
if (!repeat_enabled) {
  message("Skipping ws repeat stress test; set RDUCKS_TEST_NNG_WS_REPEAT=1 (or RDUCKS_TEST_WS_REPEAT=1) to enable")
} else if (!"ws" %in% Rducks:::rducks_nng_runtime_transports()) {
  message("Skipping ws repeat stress test; ws transport is not available")
} else if (!identical(Sys.info()[["sysname"]], "Windows")) {
  message("Skipping ws repeat stress test outside Windows by design")
} else {
  repeat_count <- as.integer(Sys.getenv("RDUCKS_TEST_WS_REPEAT_COUNT", Sys.getenv("RDUCKS_TEST_NNG_WS_REPEAT_COUNT", "3")))
  if (!is.finite(repeat_count) || repeat_count < 1L) repeat_count <- 3L
  ipc_workers <- suppressWarnings(as.integer(Sys.getenv("RDUCKS_TEST_IPC_WORKERS", "1")))
  if (!is.finite(ipc_workers) || ipc_workers < 1L) ipc_workers <- 1L

  for (i in seq_len(repeat_count)) {
    local({
      i <- i
      con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
      on.exit(
        {
          try(rducks_release(con), silent = TRUE)
          try(Rducks:::rducks_nng_stop_all_providers(quiet = TRUE), silent = TRUE)
          try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE)
        },
        add = TRUE
      )

      rducks_enable(con)
      plan <- rducks_execution_plan(
        "arrow_ipc", "multiprocess_parallel",
        ipc_transport = "ws",
        ipc_workers = ipc_workers,
        ipc_timeout = 10
      )
      rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)

      fn <- paste0("nng_ws_repeat_", sprintf("%02d", i))
      rducks_register(
        con, fn,
        function(x) x + 1L,
        INTEGER,
        INTEGER,
        mode = "vectorized",
        side_effects = TRUE
      )

      result <- DBI::dbGetQuery(
        con,
        sprintf("SELECT %s(i::INTEGER) AS x FROM range(4) t(i)", DBI::dbQuoteIdentifier(con, fn))
      )
      expect_equal(result$x, 1:4)
    })
  }
}
