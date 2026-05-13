library(Rducks)

local({
  events <- character()
  fake_backend <- list(
    name = "fake",
    capabilities = list(
      local_only = TRUE,
      supports_mori_global_sharing = TRUE,
      supports_chunk_shared_memory_handles = FALSE,
      supports_shared_memory_handles = FALSE,
      supports_cancellation = FALSE,
      supports_remote_endpoints = FALSE
    ),
    start = function(state, plan = NULL) {
      events <<- c(events, "start")
      list(endpoints = character(), cleanup_paths = character(), tasks = list())
    },
    stop = function(state, timeout, quiet = FALSE) {
      events <<- c(events, "stop")
      Rducks:::rducks_nng_shutdown_status(0L)
    },
    cleanup = function(state) {
      events <<- c(events, "cleanup")
      invisible(NULL)
    }
  )
  provider <- Rducks:::rducks_nng_provider(
    workers = 1L,
    transport = Rducks:::rducks_nng_default_transport(),
    backend = fake_backend
  )
  provider$start()
  expect_equal(provider$stats()$backend[[1L]], "fake")
  expect_true(provider$stats()$started[[1L]])
  expect_equal(provider$endpoints(), character())
  expect_true(isTRUE(provider$capabilities()$supports_mori_global_sharing))
  expect_false(isTRUE(provider$capabilities()$supports_chunk_shared_memory_handles))
  expect_false(isTRUE(provider$capabilities()$supports_shared_memory_handles))
  shutdown <- provider$stop(timeout = 1)
  expect_equal(shutdown$tasks_total, 0L)
  expect_equal(events, c("start", "stop"))
})

local({
  managed <- Rducks:::rducks_nng_provider(workers = 1L, transport = Rducks:::rducks_nng_default_transport())
  managed_caps <- managed$capabilities()
  expect_true(isTRUE(managed_caps$local_only))
  expect_true(isTRUE(managed_caps$supports_mori_global_sharing))
  expect_false(isTRUE(managed_caps$supports_chunk_shared_memory_handles))
  expect_false(isTRUE(managed_caps$supports_shared_memory_handles))

  external <- Rducks:::rducks_nng_provider(workers = 1L, endpoints = "tcp://127.0.0.1:9")
  external_caps <- external$capabilities()
  expect_false(isTRUE(external_caps$local_only))
  expect_false(isTRUE(external_caps$supports_mori_global_sharing))
  expect_false(isTRUE(external_caps$supports_chunk_shared_memory_handles))
  expect_false(isTRUE(external_caps$supports_shared_memory_handles))
  expect_true(isTRUE(external_caps$supports_remote_endpoints))
})

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
    try(rducks_release(con), silent = TRUE)
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
    rducks_register_scalar_udf(con, "nng_missing_endpoint", function(x) x + 1L, INTEGER, INTEGER, mode = "vectorized"),
    "NNG request failed|nng_"
  )

  runtime_token <- Rducks:::rducks_runtime_token(con)
  provider_records <- function() {
    store <- Rducks:::.rducks_state$nng_providers
    if (is.null(store)) return(list())
    records <- mget(ls(store, all.names = TRUE), envir = store, inherits = FALSE)
    records <- Filter(function(record) identical(record$runtime_token, runtime_token), records)
    Filter(function(record) isTRUE(record$provider$stats()$started[[1L]]), records)
  }

  plan_one <- rducks_execution_plan(
    "arrow_ipc", "multiprocess_parallel",
    ipc_workers = 1L,
    ipc_timeout = 1
  )
  rducks_set_execution_plan(con, plan_one, threads = 1L, external_threads = 1L)
  reg_one <- rducks_register_scalar_udf(
    con, "nng_lifecycle_one", function(x) x + 1L,
    INTEGER, INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  )
  expect_equal(reg_one$execution_plan$ipc_workers, 1L)
  expect_equal(DBI::dbGetQuery(con, "SELECT nng_lifecycle_one(41::INTEGER) AS x")$x, 42L)
  records_one <- provider_records()
  expect_equal(length(records_one), 1L)
  compute_one <- records_one[[1L]]$provider$stats()$compute[[1L]]

  plan_one_timeout <- rducks_execution_plan(
    "arrow_ipc", "multiprocess_parallel",
    ipc_workers = 1L,
    ipc_timeout = 2
  )
  rducks_set_execution_plan(con, plan_one_timeout, threads = 1L, external_threads = 1L)
  invisible(rducks_register_scalar_udf(
    con, "nng_lifecycle_timeout", function(x) x + 2L,
    INTEGER, INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  ))
  expect_equal(DBI::dbGetQuery(con, "SELECT nng_lifecycle_timeout(40::INTEGER) AS x")$x, 42L)
  records_timeout <- provider_records()
  expect_equal(length(records_timeout), 1L)
  expect_equal(records_timeout[[1L]]$provider$stats()$compute[[1L]], compute_one)

  plan_two <- rducks_execution_plan(
    "arrow_ipc", "multiprocess_parallel",
    ipc_workers = 2L
  )
  rducks_set_execution_plan(con, plan_two, threads = 1L, external_threads = 1L)
  reg_two <- rducks_register_scalar_udf(
    con, "nng_lifecycle_two", function(x) x + 3L,
    INTEGER, INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  )
  expect_equal(reg_two$execution_plan$ipc_workers, 2L)
  expect_equal(DBI::dbGetQuery(con, "SELECT nng_lifecycle_two(i::INTEGER) AS x FROM range(4) t(i)")$x, 3:6)
  expect_equal(length(provider_records()), 2L)

  rducks_release(con)
  expect_equal(length(provider_records()), 0L)
  expect_error(
    DBI::dbGetQuery(con, "SELECT nng_lifecycle_one(41::INTEGER) AS x"),
    "RIPC client pool is not configured"
  )
  Rducks:::rducks_nng_stop_all_providers(quiet = TRUE)
})

local({
  old_dev <- Sys.getenv("RDUCKS_DEV_SURFACES", unset = NA_character_)
  Sys.setenv(RDUCKS_DEV_SURFACES = "true")
  on.exit({
    if (is.na(old_dev)) Sys.unsetenv("RDUCKS_DEV_SURFACES") else Sys.setenv(RDUCKS_DEV_SURFACES = old_dev)
  }, add = TRUE)

  external_provider <- Rducks:::rducks_nng_provider(
    workers = 1L,
    transport = Rducks:::rducks_nng_default_transport()
  )
  external_provider$start()
  on.exit(try(external_provider$stop(quiet = TRUE), silent = TRUE), add = TRUE)

  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  plan <- rducks_execution_plan(
    "arrow_ipc", "multiprocess_parallel",
    ipc_endpoints = external_provider$endpoints(),
    ipc_workers = 1L,
    ipc_timeout = 2
  )
  rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
  invisible(rducks_register_scalar_udf(
    con, "nng_external_release_alive", function(x) x + 3L,
    INTEGER, INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  ))
  expect_equal(DBI::dbGetQuery(con, "SELECT nng_external_release_alive(39::INTEGER) AS x")$x, 42L)
  rducks_release(con)
  expect_true(external_provider$stats()$started[[1L]])
  expect_equal(DBI::dbGetQuery(con, "SELECT nng_external_release_alive(39::INTEGER) AS x")$x, 42L)
})
