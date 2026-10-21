library(Rducks)

# In-process (direct) vectorized fast result shapes: plain scalar results are
# written back from the atomic vector and STRUCT results from columns, with the
# same NULL handling, error policy, and validation as the per-row path.
local({
  if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE)) {
    exit_file("duckdb/DBI not available")
  }
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  on.exit(rducks_release(con), add = TRUE)
  q1 <- function(sql) DBI::dbGetQuery(con, sql)[[1L]][[1L]]
  reg <- function(name, fun, args, returns, ...) {
    rducks_register_scalar_udf(con, name, fun, args = args, returns = returns, mode = "vectorized", ...)
  }
  # 5000 rows: two full chunks plus a partial one; every third row NULL.
  src <- "(SELECT i, CASE WHEN i % 3 = 0 THEN NULL ELSE i * 0.5 END AS v FROM range(5000) t(i))"

  # result shaping helper
  shape <- getFromNamespace("rducks_vectorized_direct_result", "Rducks")
  expect_identical(shape(DOUBLE, c(1, 2, 3), 3L, NULL), c(1, 2, 3))
  expect_identical(shape(DOUBLE, c(1, 3), 3L, c(1L, 3L)), c(1, NA, 3))
  expect_identical(shape(INTEGER, c(1, 2), 2L, NULL), c(1, 2))
  expect_null(shape(DOUBLE, list(1, 2, 3), 3L, NULL))
  expect_error(shape(INTEGER, c(1.5, 2), 2L, NULL), pattern = "whole-number")
  cols <- shape(STRUCT(x = DOUBLE, y = INTEGER), data.frame(x = c(1, 2), y = c(3L, 4L)), 3L, c(1L, 3L))
  expect_true(inherits(cols, "rducks_columnar_result"))
  expect_identical(cols[[1L]], c(1, NA, 2))
  expect_identical(cols[[2L]], c(3L, NA, 4L))
  expect_identical(attr(cols, "rducks_row_null"), c(FALSE, TRUE, FALSE))
  expect_null(shape(STRUCT(x = DOUBLE, y = INTEGER), data.frame(x = c(1, 2)), 2L, NULL))

  reg("dvf_dbl", function(x) x * 2, list(DOUBLE), DOUBLE)
  expect_true(q1(sprintf("SELECT bool_and(dvf_dbl(v) IS NOT DISTINCT FROM v * 2) FROM %s", src)))
  expect_identical(q1(sprintf("SELECT count(*) FROM %s WHERE dvf_dbl(v) IS NULL", src)),
                   q1(sprintf("SELECT count(*) FROM %s WHERE v IS NULL", src)))
  # NaN is a value, NA is NULL
  reg("dvf_nan", function(x) ifelse(x > 10, NaN, x), list(DOUBLE), DOUBLE)
  expect_true(q1("SELECT isnan(dvf_nan(11.0)) AND dvf_nan(11.0) IS NOT NULL"))

  reg("dvf_int", function(x) as.numeric(x) + 1, list(INTEGER), INTEGER)
  expect_true(q1("SELECT bool_and(dvf_int(j) IS NOT DISTINCT FROM j + 1) FROM (SELECT CASE WHEN i % 4 = 0 THEN NULL ELSE i::INTEGER END AS j FROM range(3000) t(i))"))
  reg("dvf_int_bad", function(x) as.numeric(x) + 0.5, list(INTEGER), INTEGER)
  expect_error(q1("SELECT dvf_int_bad(i::INTEGER) FROM range(10) t(i)"), pattern = "whole-number|marshal error")
  reg("dvf_u8", function(x) x %% 200L, list(INTEGER), UTINYINT)
  expect_true(q1("SELECT bool_and(dvf_u8(i::INTEGER) = (i % 200)::UTINYINT) FROM range(3000) t(i)"))

  reg("dvf_chr", function(x, y) paste0(x, y), list(VARCHAR, INTEGER), VARCHAR)
  expect_true(q1("SELECT bool_and(dvf_chr(s, j) IS NOT DISTINCT FROM s || j::VARCHAR) FROM (SELECT CASE WHEN i % 5 = 0 THEN NULL ELSE 'v' || i END AS s, CASE WHEN i % 7 = 0 THEN NULL ELSE i::INTEGER END AS j FROM range(3000) t(i))"))
  reg("dvf_utf8", function(x) paste0(x, "é"), list(VARCHAR), VARCHAR)
  expect_identical(q1("SELECT dvf_utf8('caf')"), "café")

  reg("dvf_bool", function(x) x > 100, list(DOUBLE), BOOLEAN)
  expect_true(q1(sprintf("SELECT bool_and(dvf_bool(v) IS NOT DISTINCT FROM (v > 100)) FROM %s", src)))

  reg("dvf_special", function(x) ifelse(is.na(x), -1L, 1L), list(DOUBLE), INTEGER, null_handling = "special")
  expect_identical(q1(sprintf("SELECT sum(dvf_special(v))::BIGINT FROM %s", src)),
                   q1(sprintf("SELECT (count(v) - (count(*) - count(v)))::BIGINT FROM %s", src)))

  reg("dvf_null_on_error", function(x) stop("boom"), list(DOUBLE), DOUBLE, exception_handling = "return_null")
  expect_identical(q1("SELECT count(*) FROM (SELECT dvf_null_on_error(i * 1.0) AS r FROM range(3000) t(i)) WHERE r IS NULL"), q1("SELECT 3000::BIGINT"))
  reg("dvf_throw", function(x) stop("boom"), list(DOUBLE), DOUBLE)
  expect_error(q1("SELECT dvf_throw(i * 1.0) FROM range(10) t(i)"), pattern = "boom|marshal error")

  reg("dvf_short", function(x) x[1], list(DOUBLE), DOUBLE)
  expect_error(q1("SELECT dvf_short(i * 1.0) FROM range(10) t(i)"), pattern = "must have length|marshal error")

  # list result for an atomic type: generic per-row conversion still applies
  reg("dvf_listed", function(x) as.list(x * 2), list(DOUBLE), DOUBLE)
  expect_true(q1(sprintf("SELECT bool_and(dvf_listed(v) IS NOT DISTINCT FROM v * 2) FROM %s", src)))

  # STRUCT from a data frame: point-like result, NULL rows, nested struct, blob child
  reg("dvf_point", function(x, y) data.frame(x = x, y = y), list(DOUBLE, DOUBLE), STRUCT(x = DOUBLE, y = DOUBLE))
  expect_true(q1(sprintf("SELECT bool_and(dvf_point(v, v * 2) IS NOT DISTINCT FROM CASE WHEN v IS NULL THEN NULL ELSE {'x': v, 'y': v * 2} END) FROM %s", src)))
  expect_true(q1("SELECT dvf_point(1.0, 2.0).x = 1.0 AND dvf_point(1.0, 2.0).y = 2.0"))
  reg("dvf_point_na", function(x, y) data.frame(x = x, y = ifelse(x > 2, NA_real_, y)), list(DOUBLE, DOUBLE), STRUCT(x = DOUBLE, y = DOUBLE))
  expect_true(q1("SELECT dvf_point_na(3.0, 1.0).y IS NULL AND dvf_point_na(3.0, 1.0) IS NOT NULL AND dvf_point_na(1.0, 1.0).y = 1.0"))
  reg("dvf_nested", function(x) list(a = x, inner = data.frame(b = as.integer(x), c = paste0("s", x))),
      list(DOUBLE), STRUCT(a = DOUBLE, inner = STRUCT(b = INTEGER, c = VARCHAR)))
  expect_true(q1("SELECT bool_and(dvf_nested(i * 1.0) IS NOT DISTINCT FROM {'a': i * 1.0, 'inner': {'b': i::INTEGER, 'c': 's' || i}}) FROM range(3000) t(i)"))
  reg("dvf_struct_blob", function(x) data.frame(k = x, I(lapply(x, function(v) as.raw(c(0x01, 0x02))))) |> setNames(c("k", "b")),
      list(DOUBLE), STRUCT(k = DOUBLE, b = BLOB))
  expect_true(q1("SELECT bool_and(dvf_struct_blob(i * 1.0) IS NOT DISTINCT FROM {'k': i * 1.0, 'b': '\\x01\\x02'::BLOB}) FROM range(3000) t(i)"))
  reg("dvf_struct_missing", function(x) data.frame(x = x), list(DOUBLE), STRUCT(x = DOUBLE, y = DOUBLE))
  expect_error(q1("SELECT dvf_struct_missing(i * 1.0) FROM range(10) t(i)"), pattern = "missing field|marshal error|not compatible")
  reg("dvf_struct_extra", function(x) data.frame(x = x, y = x, z = x), list(DOUBLE), STRUCT(x = DOUBLE, y = DOUBLE))
  expect_true(q1("SELECT dvf_struct_extra(2.0) = {'x': 2.0, 'y': 2.0}"))

  # concurrent in-process plan agrees with the single-thread result. The
  # queued backend needs the main R thread to receive UDF chunks of its own to
  # drain worker requests, so scan a materialized table with several row
  # groups (a parallel source) rather than a single-threaded range() source.
  DBI::dbExecute(con, "CREATE TABLE dvf_big AS SELECT i, CASE WHEN i % 3 = 0 THEN NULL ELSE i * 0.5 END AS v FROM range(600000) t(i)")
  rducks_set_execution_plan(con, rducks_execution_plan("inproc"), threads = 4L, external_threads = 1L)
  expect_true(q1("SELECT bool_and(dvf_point(v, v * 2) IS NOT DISTINCT FROM CASE WHEN v IS NULL THEN NULL ELSE {'x': v, 'y': v * 2} END) FROM dvf_big"))
  expect_true(q1("SELECT bool_and(dvf_dbl(v) IS NOT DISTINCT FROM v * 2) FROM dvf_big"))
  rducks_set_execution_plan(con, rducks_execution_plan("inproc"), threads = 1L, external_threads = 1L)
})
