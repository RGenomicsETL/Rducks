library(Rducks)

rducks_nng_transport_marker <- function(label) {
  message("[rducks-nng-transport] ", label)
  flush.console()
}

rducks_nng_transports_body <- function(only = NULL) {
  rducks_nng_transport_marker(paste("start", if (is.null(only)) "all" else only))
  old_dev <- Sys.getenv("RDUCKS_DEV_SURFACES", unset = NA_character_)
  Sys.setenv(RDUCKS_DEV_SURFACES = "true")
  on.exit({
    if (is.na(old_dev)) Sys.unsetenv("RDUCKS_DEV_SURFACES") else Sys.setenv(RDUCKS_DEV_SURFACES = old_dev)
  }, add = TRUE)
  rducks_nng_transport_marker("before connect")
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  rducks_nng_transport_marker("after connect")
  on.exit({
    try(Rducks:::rducks_nng_stop_all_providers(quiet = TRUE), silent = TRUE)
    DBI::dbDisconnect(con, shutdown = TRUE)
  }, add = TRUE)
  rducks_nng_transport_marker("before enable")
  rducks_enable(con)
  rducks_nng_transport_marker("after enable")

  rducks_nng_transport_marker("before enabled query")
  enabled <- DBI::dbGetQuery(con, "SELECT rducks_nng_enabled() AS enabled")$enabled[[1L]]
  rducks_nng_transport_marker("after enabled query")
  expect_true(enabled)
  rducks_nng_transport_marker("before self test")
  expect_true(DBI::dbGetQuery(con, "SELECT rducks_nng_self_test() AS ok")$ok[[1L]])
  rducks_nng_transport_marker("after self test")

  transports <- Rducks:::rducks_nng_runtime_transports()
  expect_true(all(c("ipc", "tcp", "ws") %in% transports))
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
  if (!is.null(only)) transports <- intersect(transports, only)
  expect_true(length(transports) >= 1L)
  ipc_workers <- suppressWarnings(as.integer(Sys.getenv("RDUCKS_TEST_IPC_WORKERS", "1")))
  if (length(ipc_workers) != 1L || is.na(ipc_workers) || ipc_workers < 1L) ipc_workers <- 1L

  for (transport in transports) {
    rducks_nng_transport_marker(paste("transport", transport, "before stop_all"))
    Rducks:::rducks_nng_stop_all_providers(quiet = TRUE)
    rducks_nng_transport_marker(paste("transport", transport, "before plan"))
    plan <- rducks_execution_plan(
      "arrow_ipc", "multiprocess_parallel",
      ipc_transport = transport,
      ipc_workers = ipc_workers,
      ipc_timeout = 10
    )
    expect_equal(plan$ipc_options$transport, transport)
    rducks_nng_transport_marker(paste("transport", transport, "before set plan"))
    rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
    name <- paste0("nng_transport_", gsub("[^[:alnum:]]+", "_", transport))
    rducks_nng_transport_marker(paste("transport", transport, "before register"))
    reg <- rducks_register(
      con, name,
      function(x) x + 1L,
      INTEGER, INTEGER,
      mode = "vectorized",
      side_effects = TRUE
    )
    expect_equal(reg$execution_plan$plan_id, "arrow_ipc+multiprocess_parallel")
    rducks_nng_transport_marker(paste("transport", transport, "before query"))
    result <- DBI::dbGetQuery(con, sprintf(
      "SELECT %s(i::INTEGER) AS x FROM range(4) t(i)",
      DBI::dbQuoteIdentifier(con, name)
    ))
    rducks_nng_transport_marker(paste("transport", transport, "after query"))
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

if (identical(Sys.getenv("RDUCKS_NNG_TRANSPORTS_CHILD"), "true") ||
    !identical(Sys.info()[["sysname"]], "Windows")) {
  only <- Sys.getenv("RDUCKS_NNG_TRANSPORT_ONLY", unset = NA_character_)
  rducks_nng_transports_body(if (is.na(only) || !nzchar(only)) NULL else only)
} else {
  transports <- Rducks:::rducks_nng_runtime_transports()
  for (transport in transports) {
    script <- paste(
      sprintf("Sys.setenv(RDUCKS_NNG_TRANSPORTS_CHILD = 'true', RDUCKS_NNG_TRANSPORT_ONLY = '%s')", transport),
      "tinytest::run_test_file(system.file('tinytest', 'test_zzzy_duckdb_runtime_nng_transports.R', package = 'Rducks'))",
      sep = "; "
    )
    output <- tempfile(paste0("rducks-nng-transport-", transport, "-"), fileext = ".log")
    status <- system2(
      file.path(R.home("bin"), "Rscript"),
      c("--vanilla", "-e", shQuote(script)),
      stdout = output,
      stderr = output
    )
    if (file.exists(output)) {
      cat(paste(readLines(output, warn = FALSE), collapse = "\n"), "\n", sep = "")
    }
    expect_equal(status, 0L)
  }
}
