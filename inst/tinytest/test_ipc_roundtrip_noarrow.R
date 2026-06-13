library(Rducks)

# Worker-process (ipc) roundtrip over the Quack wire codec. Spawns mirai daemons,
# so it is gated behind RDUCKS_RUN_IPC_TESTS to keep the default check/CRAN run
# free of worker-process orchestration.
local({
  if (!identical(tolower(Sys.getenv("RDUCKS_RUN_IPC_TESTS", "")), "true")) {
    exit_file("ipc roundtrip test disabled (set RDUCKS_RUN_IPC_TESTS=true)")
  }
  if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE) ||
      !requireNamespace("mirai", quietly = TRUE) || !requireNamespace("nanonext", quietly = TRUE)) {
    exit_file("ipc dependencies not available")
  }
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  on.exit(rducks_release(con), add = TRUE)

  plan <- rducks_execution_plan("ipc", ipc_workers = 2L, ipc_timeout = 60)
  expect_equal(plan$engine_id, "ipc_nng_pool")

  # Register single-threaded under the ipc plan (starts workers + broadcasts UDF).
  rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
  rducks_register_scalar_udf(con, "f_ipc", function(x) x + 1L, args = list(INTEGER), returns = INTEGER)
  rducks_register_scalar_udf(con, "g_ipc", function(x) paste0("w", x), args = list(INTEGER), returns = VARCHAR)
  # Bump DuckDB threads for concurrent off-main execution -> NNG worker roundtrip.
  rducks_set_execution_plan(con, plan, threads = 3L, external_threads = 2L)

  src <- "(SELECT (i % 500)::INTEGER i FROM range(8000) t(i))"
  int_mismatch <- DBI::dbGetQuery(con, sprintf("SELECT count(*) c FROM %s WHERE f_ipc(i) <> i + 1", src))$c
  str_mismatch <- DBI::dbGetQuery(con, sprintf("SELECT count(*) c FROM %s WHERE g_ipc(i) <> 'w' || i::VARCHAR", src))$c
  expect_equal(as.integer(int_mismatch), 0L)
  expect_equal(as.integer(str_mismatch), 0L)
})
