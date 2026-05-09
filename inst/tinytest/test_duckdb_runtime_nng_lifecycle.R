library(Rducks)

local({
  old_dev <- Sys.getenv("RDUCKS_DEV_SURFACES", unset = NA_character_)
  Sys.setenv(RDUCKS_DEV_SURFACES = "true")
  on.exit({
    if (is.na(old_dev)) Sys.unsetenv("RDUCKS_DEV_SURFACES") else Sys.setenv(RDUCKS_DEV_SURFACES = old_dev)
  }, add = TRUE)

  provider <- Rducks:::rducks_nng_provider(workers = 1L, transport = Rducks:::rducks_nng_default_transport())
  provider$start()
  shutdown <- provider$stop(timeout = 2)
  expect_equal(shutdown$tasks_total, 1L)
  expect_equal(shutdown$tasks_unresolved, 0L)
  expect_false(shutdown$forced_daemon_shutdown)

  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
  on.exit({
    try(Rducks:::rducks_nng_stop_all_providers(quiet = TRUE), silent = TRUE)
    DBI::dbDisconnect(con, shutdown = TRUE)
  }, add = TRUE)
  rducks_enable(con, threads = "single")

  bad_plan <- rducks_execution_plan(
    "arrow_ipc", "multiprocess_parallel",
    ipc_endpoints = "tcp://127.0.0.1:9",
    ipc_workers = 1L,
    ipc_timeout = 0.2
  )
  rducks_set_execution_plan(con, bad_plan, threads = 1L, external_threads = 1L)
  expect_error(
    rducks_register(con, "nng_missing_endpoint", function(x) x + 1L, INTEGER, INTEGER, mode = "vectorized"),
    "NNG request failed|nng_"
  )

  plan_one <- rducks_execution_plan(
    "arrow_ipc", "multiprocess_parallel",
    ipc_workers = 1L,
    ipc_timeout = 1
  )
  rducks_set_execution_plan(con, plan_one, threads = 1L, external_threads = 1L)
  reg_one <- rducks_register(
    con, "nng_lifecycle_one", function(x) x + 1L,
    INTEGER, INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  )
  expect_equal(reg_one$execution_plan$ipc_workers, 1L)
  expect_equal(DBI::dbGetQuery(con, "SELECT nng_lifecycle_one(41::INTEGER) AS x")$x, 42L)

  Rducks:::rducks_nng_stop_all_providers(quiet = TRUE)
  expect_error(
    DBI::dbGetQuery(con, "SELECT nng_lifecycle_one(41::INTEGER) AS x"),
    "RIPC|nng_|timed out|failed"
  )

  plan_two <- rducks_execution_plan(
    "arrow_ipc", "multiprocess_parallel",
    ipc_workers = 2L
  )
  rducks_set_execution_plan(con, plan_two, threads = 1L, external_threads = 1L)
  reg_two <- rducks_register(
    con, "nng_lifecycle_two", function(x) x + 2L,
    INTEGER, INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  )
  expect_equal(reg_two$execution_plan$ipc_workers, 2L)
  expect_equal(DBI::dbGetQuery(con, "SELECT nng_lifecycle_two(i::INTEGER) AS x FROM range(4) t(i)")$x, 2:5)

  stats <- Rducks:::rducks_nng_provider_for_runtime(
    runtime_token = Rducks:::rducks_runtime_token(con),
    workers = 2L,
    max_pending = 64L,
    endpoints = NULL,
    transport = Rducks:::rducks_nng_default_transport()
  )$stats()
  expect_equal(stats$workers, 2L)
})
