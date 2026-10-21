library(Rducks)

# Worker-process fast path for vectorized UDFs over plain scalar wire types:
# semantics must match the generic path (NULL handling, error policy, result
# validation, BLOB/GEOMETRY list results). Spawns mirai daemons, so it is gated
# like the other ipc tests. The gate must stay at file top level.
if (!identical(tolower(Sys.getenv("RDUCKS_RUN_IPC_TESTS", "")), "true")) {
  exit_file("ipc vectorized fast-path test disabled (set RDUCKS_RUN_IPC_TESTS=true)")
}
if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE) ||
    !requireNamespace("mirai", quietly = TRUE) || !requireNamespace("nanonext", quietly = TRUE)) {
  exit_file("ipc dependencies not available")
}

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(
    allow_unsigned_extensions = "true",
    autoload_known_extensions = "false",
    autoinstall_known_extensions = "false"
  )))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  on.exit(rducks_release(con), add = TRUE)

  plan <- rducks_execution_plan("ipc", ipc_workers = 2L, ipc_timeout = 60)
  rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
  q1 <- function(sql) DBI::dbGetQuery(con, sql)[[1L]][[1L]]
  # 5000 rows: two full DuckDB chunks plus a partial one; every third row NULL.
  src <- "(SELECT i, CASE WHEN i % 3 = 0 THEN NULL ELSE i * 0.5 END AS v FROM range(5000) t(i))"

  # The plan is built per registered UDF in the worker; it must accept this
  # signature without touching the generic path's semantics.
  fast_plan <- getFromNamespace("rducks_ipc_worker_fast_plan", "Rducks")
  p <- fast_plan(list(mode = "vectorized", arg_types = list(DOUBLE, VARCHAR), return_type = INTEGER))
  expect_identical(p$return_kind, "scalar")
  expect_identical(p$na_template, NA_integer_)
  expect_identical(fast_plan(list(mode = "vectorized", arg_types = list(DOUBLE), return_type = GEOMETRY))$return_kind, "blob")
  expect_null(fast_plan(list(mode = "scalar", arg_types = list(DOUBLE), return_type = DOUBLE)))
  expect_null(fast_plan(list(mode = "vectorized", arg_types = NULL, return_type = DOUBLE)))
  expect_null(fast_plan(list(mode = "vectorized", arg_types = list(DATE), return_type = DOUBLE)))
  expect_null(fast_plan(list(mode = "vectorized", arg_types = list(DOUBLE), return_type = BIGINT)))

  rducks_register_scalar_udf(con, "ipcf_dbl", function(x) x * 2, args = list(DOUBLE), returns = DOUBLE, mode = "vectorized")
  expect_true(q1(sprintf("SELECT bool_and(ipcf_dbl(v) IS NOT DISTINCT FROM v * 2) FROM %s", src)))
  expect_identical(q1(sprintf("SELECT count(*) FROM %s WHERE ipcf_dbl(v) IS NULL", src)), q1(sprintf("SELECT count(*) FROM %s WHERE v IS NULL", src)))

  # integer result returned as whole doubles: validated and coerced like the generic path
  rducks_register_scalar_udf(con, "ipcf_int", function(x) as.numeric(x) + 1, args = list(INTEGER), returns = INTEGER, mode = "vectorized")
  expect_true(q1("SELECT bool_and(ipcf_int(j) IS NOT DISTINCT FROM j + 1) FROM (SELECT CASE WHEN i % 4 = 0 THEN NULL ELSE i::INTEGER END AS j FROM range(3000) t(i))"))
  rducks_register_scalar_udf(con, "ipcf_int_bad", function(x) as.numeric(x) + 0.5, args = list(INTEGER), returns = INTEGER, mode = "vectorized")
  expect_error(q1("SELECT ipcf_int_bad(i::INTEGER) FROM range(10) t(i)"), pattern = "whole-number")

  rducks_register_scalar_udf(con, "ipcf_chr", function(x, y) paste0(x, y), args = list(VARCHAR, INTEGER), returns = VARCHAR, mode = "vectorized")
  expect_true(q1("SELECT bool_and(ipcf_chr(s, j) IS NOT DISTINCT FROM s || j::VARCHAR) FROM (SELECT CASE WHEN i % 5 = 0 THEN NULL ELSE 'v' || i END AS s, CASE WHEN i % 7 = 0 THEN NULL ELSE i::INTEGER END AS j FROM range(3000) t(i))"))

  rducks_register_scalar_udf(con, "ipcf_bool", function(x) x > 100, args = list(DOUBLE), returns = BOOLEAN, mode = "vectorized")
  expect_true(q1(sprintf("SELECT bool_and(ipcf_bool(v) IS NOT DISTINCT FROM (v > 100)) FROM %s", src)))

  # special NULL handling: the R function sees NA and decides
  rducks_register_scalar_udf(con, "ipcf_special", function(x) ifelse(is.na(x), -1L, 1L),
    args = list(DOUBLE), returns = INTEGER, mode = "vectorized", null_handling = "special")
  expect_identical(q1(sprintf("SELECT sum(ipcf_special(v))::BIGINT FROM %s", src)),
                   q1(sprintf("SELECT (count(v) - (count(*) - count(v)))::BIGINT FROM %s", src)))

  # error policy
  rducks_register_scalar_udf(con, "ipcf_null_on_error", function(x) stop("boom"),
    args = list(DOUBLE), returns = DOUBLE, mode = "vectorized", exception_handling = "return_null")
  expect_identical(q1("SELECT count(*) FROM (SELECT ipcf_null_on_error(i * 1.0) AS r FROM range(3000) t(i)) WHERE r IS NULL"), q1("SELECT 3000::BIGINT"))
  rducks_register_scalar_udf(con, "ipcf_throw", function(x) stop("boom"), args = list(DOUBLE), returns = DOUBLE, mode = "vectorized")
  expect_error(q1("SELECT ipcf_throw(i * 1.0) FROM range(10) t(i)"), pattern = "boom")

  # wrong length is rejected
  rducks_register_scalar_udf(con, "ipcf_short", function(x) x[1], args = list(DOUBLE), returns = DOUBLE, mode = "vectorized")
  expect_error(q1("SELECT ipcf_short(i * 1.0) FROM range(10) t(i)"), pattern = "must have length")

  # a list result for an atomic return type falls back to the generic conversion
  rducks_register_scalar_udf(con, "ipcf_listed", function(x) as.list(x * 2), args = list(DOUBLE), returns = DOUBLE, mode = "vectorized")
  expect_true(q1(sprintf("SELECT bool_and(ipcf_listed(v) IS NOT DISTINCT FROM v * 2) FROM %s", src)))

  # BLOB / GEOMETRY list results, NULL rows, classed list
  wkb_point <- function(x, y) c(as.raw(1L), as.raw(c(1L, 0L, 0L, 0L)), writeBin(c(x, y), raw(), size = 8L, endian = "little"))
  rducks_register_scalar_udf(con, "ipcf_blob", function(x) lapply(x, function(v) as.raw(c(0x01, 0x02))),
    args = list(DOUBLE), returns = BLOB, mode = "vectorized")
  expect_true(q1(sprintf("SELECT bool_and(ipcf_blob(v) IS NOT DISTINCT FROM CASE WHEN v IS NULL THEN NULL ELSE '\\x01\\x02'::BLOB END) FROM %s", src)))
  rducks_register_scalar_udf(con, "ipcf_geom",
    function(x, y) structure(lapply(seq_along(x), function(i) wkb_point(x[[i]], y[[i]])), class = "some_classed_list"),
    args = list(DOUBLE, DOUBLE), returns = GEOMETRY, mode = "vectorized")
  expect_true(q1("SELECT bool_and(ipcf_geom(i * 1.0, i * 2.0) = ('POINT(' || i || ' ' || (2 * i) || ')')::GEOMETRY) FROM range(3000) t(i)"))
  rducks_register_scalar_udf(con, "ipcf_blob_bad", function(x) as.list(x), args = list(DOUBLE), returns = BLOB, mode = "vectorized")
  expect_error(q1("SELECT ipcf_blob_bad(i * 1.0) FROM range(10) t(i)"), pattern = "not compatible with BLOB")

  # DuckDB concurrency across both workers still agrees with the single-thread result
  rducks_set_execution_plan(con, plan, threads = 4L, external_threads = 1L)
  expect_true(q1(sprintf("SELECT bool_and(ipcf_dbl(v) IS NOT DISTINCT FROM v * 2) FROM %s", src)))
  rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
})
