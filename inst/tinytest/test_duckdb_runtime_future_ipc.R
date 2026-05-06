Sys.setenv(RDUCKS_DEV_SURFACES = "true")
library(Rducks)

rducks_test_stress_concurrency <- function() {
  tolower(Sys.getenv("RDUCKS_STRESS_CONCURRENCY", "false")) %in% c("1", "true", "yes")
}

rducks_test_future_workers <- function(default = 1L, cap = 2L) {
  workers <- suppressWarnings(as.integer(Sys.getenv("RDUCKS_TEST_FUTURE_WORKERS", as.character(default))))
  if (length(workers) != 1L || is.na(workers) || workers < 1L) workers <- default
  workers <- max(1L, workers)
  if (!rducks_test_stress_concurrency()) workers <- min(workers, cap)
  workers
}

local({
  old_future_plan <- future::plan()
  on.exit(future::plan(old_future_plan), add = TRUE)
  future::plan(future::multisession, workers = rducks_test_future_workers())

  expect_true(Rducks:::rducks_arrow_ipc_mapping_supported(INTEGER))
  expect_equal(Rducks:::rducks_arrow_ipc_unsupported_types(INTEGER), character())
  expect_true(Rducks:::rducks_arrow_ipc_mapping_supported(STRUCT(x = LIST(ENUM(c("red", "blue"))))))
  expect_equal(Rducks:::rducks_arrow_ipc_unsupported_types(MAP(VARCHAR, DECIMAL(10, 2))), character())
  expect_error(Rducks:::rducks_arrow_ipc_mapping_supported("list<i32>"), "constructors")
  expect_error(Rducks:::rducks_arrow_ipc_encode(list()), "nanoarrow_array")
  expect_error(Rducks:::rducks_arrow_ipc_decode_array(raw()), "record batch|Arrow|IPC|schema|Invalid|read")
  expect_error(Rducks:::rducks_arrow_ipc_decode_array(as.raw(c(1L, 2L, 3L, 4L))), "record batch|Arrow|IPC|schema|Invalid|read")

  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  offset <- 10L
  plan <- rducks_execution_plan(
    "arrow_ipc", "multiprocess_parallel",
    future_packages = "stats",
    future_timeout = 30
  )
  rducks_set_execution_plan(con, plan)

  invisible(rducks_register(
    con, "future_ipc_plus_offset",
    function(x) x + offset + as.integer(stats::median(1L)),
    INTEGER, INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  ))

  out <- DBI::dbGetQuery(con, "SELECT future_ipc_plus_offset(i::INTEGER) AS x FROM range(5) AS t(i)")
  expect_equal(out$x, 11:15)

  invisible(rducks_register(
    con, "future_ipc_bad_integer_result",
    function(x) rep(NaN, length(x)),
    INTEGER, INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  ))
  expect_error(
    DBI::dbGetQuery(con, "SELECT future_ipc_bad_integer_result(i::INTEGER) AS x FROM range(3) AS t(i)"),
    "Future Arrow IPC|worker|marshal|Rducks"
  )
  expect_equal(DBI::dbGetQuery(con, "SELECT future_ipc_plus_offset(1::INTEGER) AS x")$x, 12L)

  explain <- rducks_explain_udf(con, "future_ipc_plus_offset")
  expect_equal(explain$marshalling, "arrow_ipc")
  expect_equal(explain$native_marshalling, "arrow_ipc")
  expect_equal(explain$evaluator, "RIPC")
  expect_true(explain$queued_chunks >= 1)
  expect_true(explain$arrow_ipc_chunks >= 1)
  expect_true(explain$ripc_collect_batches >= 1)
  expect_equal(explain$ripc_collect_requests, explain$arrow_ipc_chunks)
  expect_true(explain$ripc_collect_max_batch >= 1)
  expect_equal(explain$queue_pending_current, 0)
  expect_equal(explain$ripc_inflight_current, 0)
  expect_true(explain$ripc_inflight_max >= 1)
  expect_equal(explain$arrow_r_chunks, 0)
  expect_equal(explain$arrow_c_chunks, 0)

  invisible(rducks_register(
    con, "future_ipc_pure_plus_one",
    function(x) x + 1L,
    INTEGER, INTEGER,
    mode = "vectorized",
    side_effects = FALSE
  ))
  pure_out <- DBI::dbGetQuery(con, "SELECT future_ipc_pure_plus_one(i::INTEGER) AS x FROM range(5) AS t(i)")
  expect_equal(pure_out$x, 1:5)
  pure_explain <- rducks_explain_udf(con, "future_ipc_pure_plus_one")
  expect_equal(pure_explain$evaluator, "RIPC")
  expect_false(pure_explain$side_effects)
  expect_true(pure_explain$arrow_ipc_chunks >= 1)

  invisible(rducks_register(
    con, "future_ipc_null_default",
    function(x) x + 1L,
    INTEGER, INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  ))
  null_out <- DBI::dbGetQuery(
    con,
    "SELECT future_ipc_null_default(x) AS y FROM (VALUES (1::INTEGER), (NULL::INTEGER), (3::INTEGER)) AS t(x)"
  )
  expect_equal(null_out$y, c(2L, NA_integer_, 4L))

  invisible(rducks_register(
    con, "future_ipc_scalar_plus_one",
    function(x) {
      if (!identical(length(x), 1L)) stop("expected one scalar value")
      x + 1L
    },
    INTEGER, INTEGER,
    mode = "scalar",
    side_effects = TRUE
  ))
  scalar_out <- DBI::dbGetQuery(con, "SELECT future_ipc_scalar_plus_one(i::INTEGER) AS x FROM range(5) AS t(i)")
  expect_equal(scalar_out$x, 1:5)
  scalar_explain <- rducks_explain_udf(con, "future_ipc_scalar_plus_one")
  expect_equal(scalar_explain$mode, "scalar")
  expect_equal(scalar_explain$evaluator, "RIPC")
  expect_true(scalar_explain$side_effects)
  expect_true(scalar_explain$arrow_ipc_chunks >= 1)
  expect_true(scalar_explain$ripc_collect_batches >= 1)
  expect_equal(scalar_explain$ripc_collect_requests, scalar_explain$arrow_ipc_chunks)

  invisible(rducks_register(
    con, "future_ipc_enum_echo",
    function(x) x,
    ENUM(c("red", "blue")), ENUM(c("red", "blue")),
    mode = "vectorized",
    side_effects = TRUE
  ))
  enum_out <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT future_ipc_enum_echo(x)::VARCHAR AS x",
      "FROM (VALUES ('red'::ENUM('red','blue')), ('blue'::ENUM('red','blue'))) AS t(x)"
    )
  )
  expect_equal(enum_out$x, c("red", "blue"))
  enum_explain <- rducks_explain_udf(con, "future_ipc_enum_echo")
  expect_equal(enum_explain$evaluator, "RIPC")
  expect_true(enum_explain$arrow_ipc_chunks >= 1)

  if (rducks_test_stress_concurrency()) {
    stress_workers <- max(2L, rducks_test_future_workers(default = 2L, cap = 4L))
    future::plan(future::multisession, workers = stress_workers)
    invisible(rducks_register(
      con, "future_ipc_parallel_sleep",
      function(x) {
        Sys.sleep(0.02)
        as.numeric(x) + 1
      },
      UBIGINT, DOUBLE,
      mode = "vectorized",
      side_effects = TRUE
    ))
    rducks_set_execution_plan(con, plan, threads = stress_workers + 1L, external_threads = 1L)
    parallel_out <- DBI::dbGetQuery(
      con,
      "SELECT sum(future_ipc_parallel_sleep(i)) AS x FROM rducks_parallel_range(8192::UBIGINT)"
    )
    expect_equal(parallel_out$x, sum(seq_len(8192)))
    parallel_explain <- rducks_explain_udf(con, "future_ipc_parallel_sleep")
    expect_true(parallel_explain$queue_pending_max >= 2)
    expect_true(parallel_explain$ripc_inflight_max >= 2)
    expect_true(parallel_explain$ripc_submit_wave_max >= 2)
    expect_true(parallel_explain$ripc_collect_ready_max >= 2)
    expect_true(parallel_explain$ripc_collect_max_batch >= 2)
  }
})
