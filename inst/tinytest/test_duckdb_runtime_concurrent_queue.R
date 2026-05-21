Sys.setenv(RDUCKS_DEV_SURFACES = "true")
library(Rducks)

rducks_test_stress_concurrency <- function() {
  tolower(Sys.getenv("RDUCKS_STRESS_CONCURRENCY", "false")) %in% c("1", "true", "yes")
}

rducks_test_duckdb_threads <- function(default = 8L) {
  threads <- suppressWarnings(as.integer(Sys.getenv("RDUCKS_TEST_DUCKDB_THREADS", as.character(default))))
  if (length(threads) != 1L || is.na(threads) || threads < 1L) threads <- default
  max(1L, threads)
}

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  before <- rducks_inproc_stats(con)
  expect_equal(names(before), c(
    "submitted", "executed", "timeouts", "pending_current", "pending_max",
    "running_current", "running_max", "main_drains", "main_drain_batches",
    "main_drain_max_batch", "pending_timeout_ms", "running_timeout_supported"
  ))
  expect_equal(before$submitted, 0)
  expect_equal(before$executed, 0)
  expect_equal(before$timeouts, 0)
  expect_equal(before$pending_current, 0)
  expect_equal(before$pending_max, 0)
  expect_equal(before$running_current, 0)
  expect_equal(before$running_max, 0)
  expect_equal(before$main_drains, 0)
  expect_equal(before$main_drain_batches, 0)
  expect_equal(before$main_drain_max_batch, 0)
  expect_true(before$pending_timeout_ms[[1L]] > 0)
  expect_false(before$running_timeout_supported[[1L]])

  self_test <- rducks_inproc_self_test(con, 3)
  expect_equal(self_test, 3)

  after <- rducks_inproc_stats(con)
  expect_equal(after$submitted, 3)
  expect_equal(after$executed, 3)
  expect_equal(after$timeouts, 0)
  expect_equal(after$pending_current, 0)
  expect_true(after$pending_max >= 1)
  expect_equal(after$running_current, 0)
  expect_true(after$running_max >= 1)
  expect_true(after$main_drains >= 1)
  expect_true(after$main_drain_batches >= 1)
  expect_true(after$main_drain_max_batch >= 1)


  invisible(rducks_register_scalar_udf(con, "rducks_queue_plus_one", function(x) x + 1, DOUBLE, DOUBLE))
  invisible(rducks_register_scalar_udf(con, "rducks_queue_plus_one_vec", function(x) x + 1, DOUBLE, DOUBLE,
                            mode = "vectorized", side_effects = TRUE))
  rducks_enable_inproc(con)
  expect_equal(rducks_current_execution_plan(con)$plan_id, "arrow_r+inproc_concurrent")

  queued_result <- DBI::dbGetQuery(con, "SELECT sum(rducks_queue_plus_one(i::DOUBLE)) AS x FROM rducks_parallel_range(10::UBIGINT) AS t(i)")
  expect_equal(queued_result$x, sum((0:9) + 1))

  queued_vec_result <- DBI::dbGetQuery(con, "SELECT sum(rducks_queue_plus_one_vec(i::DOUBLE)) AS x FROM rducks_parallel_range(10::UBIGINT) AS t(i)")
  expect_equal(queued_vec_result$x, sum((0:9) + 1))

  invisible(rducks_register_scalar_udf(con, "rducks_queue_arrow_r_list", function(x) c(x, x + 1L), INTEGER, INTEGER[]))
  invisible(rducks_register_scalar_udf(con, "rducks_queue_arrow_r_struct", function(x) list(a = x, b = x + 1L), INTEGER, STRUCT(a = INTEGER, b = INTEGER)))
  queued_r_list_result <- DBI::dbGetQuery(
    con,
    "SELECT sum(list_sum(rducks_queue_arrow_r_list(i::INTEGER))) AS x FROM rducks_parallel_range(5::UBIGINT) AS t(i)"
  )
  expect_equal(queued_r_list_result$x, sum((0:4) + (1:5)))
  queued_r_struct_result <- DBI::dbGetQuery(
    con,
    "SELECT sum((rducks_queue_arrow_r_struct(i::INTEGER)).b) AS x FROM rducks_parallel_range(5::UBIGINT) AS t(i)"
  )
  expect_equal(queued_r_struct_result$x, sum(1:5))
  arrow_r_list_explain <- rducks_explain_udf(con, "rducks_queue_arrow_r_list")
  expect_equal(arrow_r_list_explain$evaluator, "R")
  expect_true(arrow_r_list_explain$arrow_r_chunks >= 1)
  arrow_r_struct_explain <- rducks_explain_udf(con, "rducks_queue_arrow_r_struct")
  expect_equal(arrow_r_struct_explain$evaluator, "R")
  expect_true(arrow_r_struct_explain$arrow_r_chunks >= 1)

  final <- rducks_inproc_stats(con)
  expect_true(final$submitted[[1L]] >= after$submitted[[1L]])
  expect_equal(final$submitted, final$executed)
  expect_equal(final$timeouts, 0)
})

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  rducks_set_execution_plan(con, rducks_execution_plan("arrow_c", "serial"))

  invisible(rducks_register_scalar_udf(con, "rducks_queue_plus_one_c", function(x) x + 1, DOUBLE, DOUBLE))
  invisible(rducks_register_scalar_udf(con, "rducks_queue_plus_one_c_vec", function(x) x + 1, DOUBLE, DOUBLE,
                            mode = "vectorized", side_effects = TRUE))
  rducks_enable_inproc(con)
  expect_equal(rducks_current_execution_plan(con)$plan_id, "arrow_c+inproc_concurrent")

  before <- rducks_inproc_stats(con)
  queued_c_result <- DBI::dbGetQuery(con, "SELECT sum(rducks_queue_plus_one_c(i::DOUBLE)) AS x FROM rducks_parallel_range(10::UBIGINT) AS t(i)")
  expect_equal(queued_c_result$x, sum((0:9) + 1))
  queued_c_input_null_result <- DBI::dbGetQuery(
    con,
    "SELECT rducks_queue_plus_one_c(CASE WHEN i = 1 THEN NULL::DOUBLE ELSE i::DOUBLE END) AS x FROM rducks_parallel_range(3::UBIGINT) AS t(i) ORDER BY i"
  )
  expect_equal(queued_c_input_null_result$x, c(1, NA, 3))
  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_null_i32",
    function(x) if (identical(x, 1L)) NULL else x + 1L,
    INTEGER, INTEGER
  ))
  queued_c_null_result <- DBI::dbGetQuery(
    con,
    "SELECT rducks_queue_arrow_c_null_i32(i::INTEGER) AS x FROM rducks_parallel_range(3::UBIGINT) AS t(i) ORDER BY i"
  )
  expect_equal(queued_c_null_result$x, c(1L, NA_integer_, 3L))
  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_bool",
    function(x) x %% 2L == 0L,
    INTEGER, BOOLEAN
  ))
  queued_c_bool_result <- DBI::dbGetQuery(
    con,
    "SELECT rducks_queue_arrow_c_bool(i::INTEGER) AS x FROM rducks_parallel_range(4::UBIGINT) AS t(i) ORDER BY i"
  )
  expect_equal(queued_c_bool_result$x, c(TRUE, FALSE, TRUE, FALSE))
  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_varchar",
    function(x) if (identical(x, 1L)) NA_character_ else if (identical(x, 0L)) "" else paste0("v", x),
    INTEGER, VARCHAR
  ))
  queued_c_varchar_result <- DBI::dbGetQuery(
    con,
    "SELECT rducks_queue_arrow_c_varchar(i::INTEGER) AS x FROM rducks_parallel_range(3::UBIGINT) AS t(i) ORDER BY i"
  )
  expect_equal(queued_c_varchar_result$x, c("", NA_character_, "v2"))
  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_blob",
    function(x) as.raw(c(x, 255L)),
    INTEGER, BLOB
  ))
  queued_c_blob_result <- DBI::dbGetQuery(
    con,
    "SELECT hex(rducks_queue_arrow_c_blob(i::INTEGER)) AS x FROM rducks_parallel_range(3::UBIGINT) AS t(i) ORDER BY i"
  )
  expect_equal(queued_c_blob_result$x, c("00FF", "01FF", "02FF"))
  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_bit",
    function(x) if (x %% 2L == 0L) rducks_bits(as.raw(0x80), length = 1L) else rducks_bits(as.raw(0x00), length = 1L),
    INTEGER, BIT
  ))
  queued_c_bit_result <- DBI::dbGetQuery(
    con,
    "SELECT rducks_queue_arrow_c_bit(i::INTEGER)::VARCHAR AS x FROM rducks_parallel_range(3::UBIGINT) AS t(i) ORDER BY i"
  )
  expect_equal(queued_c_bit_result$x, c("1", "0", "1"))
  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_decimal",
    function(x) rducks_decimal(sprintf("%d.25", x), 10, 2),
    INTEGER, DECIMAL(10, 2)
  ))
  queued_c_decimal_result <- DBI::dbGetQuery(
    con,
    "SELECT rducks_queue_arrow_c_decimal(i::INTEGER)::VARCHAR AS x FROM rducks_parallel_range(3::UBIGINT) AS t(i) ORDER BY i"
  )
  expect_equal(queued_c_decimal_result$x, c("0.25", "1.25", "2.25"))
  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_enum",
    function(x) if (x %% 2L == 0L) "red" else "blue",
    INTEGER, ENUM(c("red", "blue"))
  ))
  queued_c_enum_result <- DBI::dbGetQuery(
    con,
    "SELECT rducks_queue_arrow_c_enum(i::INTEGER)::VARCHAR AS x FROM rducks_parallel_range(3::UBIGINT) AS t(i) ORDER BY i"
  )
  expect_equal(queued_c_enum_result$x, c("red", "blue", "red"))
  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_uuid",
    function(x) rducks_uuid(if (x == 0L) "00000000-0000-0000-0000-000000000001" else "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"),
    INTEGER, UUID
  ))
  queued_c_uuid_result <- DBI::dbGetQuery(
    con,
    "SELECT rducks_queue_arrow_c_uuid(i::INTEGER)::VARCHAR AS x FROM rducks_parallel_range(2::UBIGINT) AS t(i) ORDER BY i"
  )
  expect_equal(queued_c_uuid_result$x, c("00000000-0000-0000-0000-000000000001", "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"))
  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_hugeint",
    function(x) rducks_hugeint(if (x == 0L) "170141183460469231731687303715884105720" else "170141183460469231731687303715884105721"),
    INTEGER, HUGEINT
  ))
  queued_c_hugeint_result <- DBI::dbGetQuery(
    con,
    "SELECT rducks_queue_arrow_c_hugeint(i::INTEGER)::VARCHAR AS x FROM rducks_parallel_range(2::UBIGINT) AS t(i) ORDER BY i"
  )
  expect_equal(queued_c_hugeint_result$x, c("170141183460469231731687303715884105720", "170141183460469231731687303715884105721"))
  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_interval",
    function(x) rducks_interval(months = x, days = x + 1L, micros = as.character(x + 2L)),
    INTEGER, INTERVAL
  ))
  queued_c_interval_result <- DBI::dbGetQuery(
    con,
    "SELECT rducks_queue_arrow_c_interval(i::INTEGER)::VARCHAR AS x FROM rducks_parallel_range(2::UBIGINT) AS t(i) ORDER BY i"
  )
  expect_equal(queued_c_interval_result$x, c("1 day 00:00:00.000002", "1 month 2 days 00:00:00.000003"))
  queued_c_vec_result <- DBI::dbGetQuery(con, "SELECT sum(rducks_queue_plus_one_c_vec(i::DOUBLE)) AS x FROM rducks_parallel_range(10::UBIGINT) AS t(i)")
  expect_equal(queued_c_vec_result$x, sum((0:9) + 1))
  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_vec_varchar",
    function(x) ifelse(x == 1L, NA_character_, paste0("vec", x)),
    INTEGER, VARCHAR,
    mode = "vectorized", side_effects = TRUE
  ))
  queued_c_vec_varchar_result <- DBI::dbGetQuery(
    con,
    "SELECT rducks_queue_arrow_c_vec_varchar(i::INTEGER) AS x FROM rducks_parallel_range(3::UBIGINT) AS t(i) ORDER BY i"
  )
  expect_equal(queued_c_vec_varchar_result$x, c("vec0", NA_character_, "vec2"))
  explain_vec_varchar <- rducks_explain_udf(con, "rducks_queue_arrow_c_vec_varchar")
  expect_equal(explain_vec_varchar$evaluator, "RCV")
  expect_true(explain_vec_varchar$arrow_c_chunks >= 1)
  expect_equal(explain_vec_varchar$arrow_r_chunks, 0)
  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_bad_i32",
    function(x) rep(NaN, length(x)),
    INTEGER, INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  ))
  expect_error(
    DBI::dbGetQuery(con, "SELECT rducks_queue_arrow_c_bad_i32(i::INTEGER) AS x FROM rducks_parallel_range(4::UBIGINT) AS t(i)"),
    "Rducks RC vectorized|marshal|integer|INTEGER"
  )
  expect_equal(DBI::dbGetQuery(con, "SELECT 3 AS ok")$ok, 3)
  explain_c <- rducks_explain_udf(con, "rducks_queue_plus_one_c")
  expect_equal(explain_c$evaluator, "RC")
  expect_true(explain_c$dispatch_chunks >= 1)
  expect_true(explain_c$queued_chunks >= 1)
  expect_true(explain_c$arrow_c_chunks >= 1)
  expect_equal(explain_c$arrow_r_chunks, 0)
  explain_c_vec <- rducks_explain_udf(con, "rducks_queue_plus_one_c_vec")
  expect_equal(explain_c_vec$evaluator, "RCV")
  expect_true(explain_c_vec$arrow_c_chunks >= 1)
  expect_equal(explain_c_vec$arrow_r_chunks, 0)
  final <- rducks_inproc_stats(con)
  expect_true(final$submitted[[1L]] >= before$submitted[[1L]])
  expect_equal(final$submitted, final$executed)
  expect_equal(final$timeouts, 0)
})

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  rducks_set_execution_plan(con, rducks_execution_plan("arrow_c", "inproc_concurrent"))

  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_snapshot_varchar_input",
    function(x) if (is.na(x)) NA_integer_ else nchar(x, type = "bytes"),
    VARCHAR, INTEGER
  ))
  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_snapshot_vec_varchar_input",
    function(x) as.integer(nchar(x, type = "bytes")),
    VARCHAR, INTEGER,
    mode = "vectorized", side_effects = TRUE
  ))
  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_owned_list_result",
    function(x) c(x, x + 1L),
    INTEGER, INTEGER[]
  ))
  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_owned_struct_result",
    function(x) data.frame(a = x, b = x + 1L),
    INTEGER, STRUCT(a = INTEGER, b = INTEGER),
    mode = "vectorized", side_effects = TRUE
  ))
  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_error_null_list",
    function(x) stop("expected list error"),
    INTEGER, INTEGER[],
    exception_handling = "return_null",
    side_effects = TRUE
  ))
  invisible(rducks_register_scalar_udf(
    con, "rducks_queue_arrow_c_error_null_struct",
    function(x) stop("expected struct error"),
    INTEGER, STRUCT(a = INTEGER, b = VARCHAR),
    exception_handling = "return_null",
    side_effects = TRUE
  ))

  # Use multiple rducks_parallel_range() chunks. Very small ranges can be
  # scheduled entirely on a DuckDB worker thread on some DuckDB/R builds; the
  # in-process queue then has no main-thread callback available to drain it.
  snapshot_n <- 4096L
  snapshot_expected <- sum(c(
    0L,
    nchar(paste0(strrep("x", 32L), 2:(snapshot_n - 1L)), type = "bytes")
  ))
  before <- rducks_inproc_stats(con)
  rducks_enable_inproc(con, threads = 4L, external_threads = 1L)

  scalar_result <- DBI::dbGetQuery(
    con,
    sprintf(
      paste(
        "SELECT sum(rducks_queue_arrow_c_snapshot_varchar_input(",
        "CASE WHEN i = 0 THEN '' WHEN i = 1 THEN NULL::VARCHAR ELSE repeat('x', 32) || i::VARCHAR END",
        ")) AS x FROM rducks_parallel_range(%d::UBIGINT) AS t(i)"
      ),
      snapshot_n
    )
  )
  expect_equal(as.numeric(scalar_result$x), as.numeric(snapshot_expected))
  scalar_explain <- rducks_explain_udf(con, "rducks_queue_arrow_c_snapshot_varchar_input")
  expect_equal(scalar_explain$evaluator, "RC")
  expect_true(scalar_explain$queued_chunks >= 1)
  expect_true(scalar_explain$arrow_c_input_snapshot_chunks >= 1)
  expect_equal(scalar_explain$arrow_r_chunks, 0)

  vectorized_result <- DBI::dbGetQuery(
    con,
    sprintf(
      paste(
        "SELECT sum(rducks_queue_arrow_c_snapshot_vec_varchar_input(",
        "CASE WHEN i = 0 THEN '' WHEN i = 1 THEN NULL::VARCHAR ELSE repeat('y', 32) || i::VARCHAR END",
        ")) AS x FROM rducks_parallel_range(%d::UBIGINT) AS t(i)"
      ),
      snapshot_n
    )
  )
  expect_equal(as.numeric(vectorized_result$x), as.numeric(snapshot_expected))
  vectorized_explain <- rducks_explain_udf(con, "rducks_queue_arrow_c_snapshot_vec_varchar_input")
  expect_equal(vectorized_explain$evaluator, "RCV")
  expect_true(vectorized_explain$queued_chunks >= 1)
  expect_true(vectorized_explain$arrow_c_input_snapshot_chunks >= 1)
  expect_equal(vectorized_explain$arrow_r_chunks, 0)

  list_result <- DBI::dbGetQuery(
    con,
    sprintf(
      "SELECT sum(list_sum(rducks_queue_arrow_c_owned_list_result(i::INTEGER))) AS x FROM rducks_parallel_range(%d::UBIGINT) AS t(i)",
      snapshot_n
    )
  )
  expect_equal(as.numeric(list_result$x), as.numeric(snapshot_n * snapshot_n))
  list_explain <- rducks_explain_udf(con, "rducks_queue_arrow_c_owned_list_result")
  expect_equal(list_explain$evaluator, "RC")
  expect_true(list_explain$queued_chunks >= 1)
  expect_true(list_explain$arrow_c_input_snapshot_chunks >= 1)
  expect_true(list_explain$arrow_c_owned_result_chunk_chunks >= 1)
  expect_equal(list_explain$arrow_r_chunks, 0)

  struct_result <- DBI::dbGetQuery(
    con,
    sprintf(
      "SELECT sum((rducks_queue_arrow_c_owned_struct_result(i::INTEGER)).b) AS x FROM rducks_parallel_range(%d::UBIGINT) AS t(i)",
      snapshot_n
    )
  )
  expect_equal(as.numeric(struct_result$x), as.numeric(snapshot_n * (snapshot_n - 1L) / 2L + snapshot_n))
  struct_explain <- rducks_explain_udf(con, "rducks_queue_arrow_c_owned_struct_result")
  expect_equal(struct_explain$evaluator, "RCV")
  expect_true(struct_explain$queued_chunks >= 1)
  expect_true(struct_explain$arrow_c_input_snapshot_chunks >= 1)
  expect_true(struct_explain$arrow_c_owned_result_chunk_chunks >= 1)
  expect_equal(struct_explain$arrow_r_chunks, 0)

  nested_error_null <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT count(rducks_queue_arrow_c_error_null_list(i::INTEGER)) AS list_nonnull,",
      "count(rducks_queue_arrow_c_error_null_struct(i::INTEGER)) AS struct_nonnull",
      sprintf("FROM rducks_parallel_range(%d::UBIGINT) AS t(i)", snapshot_n)
    )
  )
  expect_equal(nested_error_null$list_nonnull, 0)
  expect_equal(nested_error_null$struct_nonnull, 0)

  final <- rducks_inproc_stats(con)
  expect_true(final$submitted[[1L]] > before$submitted[[1L]])
  expect_equal(final$submitted, final$executed)
  expect_equal(final$timeouts, 0)
})

if (rducks_test_stress_concurrency()) local({
  threads <- rducks_test_duckdb_threads()
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  invisible(rducks_register_scalar_udf(con, "rducks_stress_plus_one", function(x) x + 1, DOUBLE, DOUBLE,
                            mode = "vectorized", side_effects = TRUE))
  rducks_enable_inproc(con, threads = threads, external_threads = 1L)

  before <- rducks_inproc_stats(con)
  out <- DBI::dbGetQuery(
    con,
    "SELECT sum(rducks_stress_plus_one(i::DOUBLE)) AS x FROM rducks_parallel_range(4096::UBIGINT) AS t(i)"
  )
  expect_equal(out$x, sum((0:4095) + 1))

  final <- rducks_inproc_stats(con)
  expect_true(final$submitted[[1L]] > before$submitted[[1L]])
  expect_equal(final$submitted, final$executed)
  expect_equal(final$timeouts, 0)
})
