library(Rducks)

local({
  if (!requireNamespace("mori", quietly = TRUE)) {
    expect_true(TRUE)
    return(invisible(NULL))
  }

  old_dev <- Sys.getenv("RDUCKS_DEV_SURFACES", unset = NA_character_)
  Sys.setenv(RDUCKS_DEV_SURFACES = "true")
  on.exit({
    if (is.na(old_dev)) Sys.unsetenv("RDUCKS_DEV_SURFACES") else Sys.setenv(RDUCKS_DEV_SURFACES = old_dev)
  }, add = TRUE)

  shared_offsets <- as.numeric(seq_len(10000))
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
  on.exit({
    try(rducks_release(con), silent = TRUE)
    try(Rducks:::rducks_nng_stop_all_providers(quiet = TRUE), silent = TRUE)
    DBI::dbDisconnect(con, shutdown = TRUE)
  }, add = TRUE)
  rducks_enable(con, threads = "single")
  plan <- rducks_execution_plan(
    "arrow_ipc", "multiprocess_parallel",
    ipc_globals_share = "mori",
    ipc_workers = 1L,
    ipc_timeout = 5
  )
  expect_equal(plan$ipc_options$globals_share, "mori")
  rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
  invisible(rducks_register_scalar_udf(
    con, "rducks_mori_global_offset",
    function(x) x + shared_offsets[[1L]],
    DOUBLE, DOUBLE,
    mode = "vectorized",
    side_effects = TRUE
  ))
  out <- DBI::dbGetQuery(con, "SELECT rducks_mori_global_offset(i::DOUBLE) AS x FROM range(3) t(i)")
  expect_equal(out$x, c(1, 2, 3))
})
