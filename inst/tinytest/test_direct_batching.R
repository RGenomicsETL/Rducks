library(Rducks)

# The default queue preserves original R calls. Only an explicitly opted-in,
# partition-invariant UDF may fuse pending chunks into one larger call.
local({
  if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE)) {
    exit_file("duckdb/DBI not available")
  }
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  on.exit(rducks_release(con), add = TRUE)
  q1 <- function(sql) DBI::dbGetQuery(con, sql)[[1L]][[1L]]
  plan <- rducks_execution_plan("inproc")

  call_lengths <- integer()
  segmented <- rducks_register_scalar_udf(con, "bt_dbl", function(x) { call_lengths <<- c(call_lengths, length(x)); x * 2 },
    args = list(DOUBLE), returns = DOUBLE, mode = "vectorized", side_effects = TRUE)
  expect_false(segmented$coalesce)
  expect_false(rducks_explain_udf(con, "bt_dbl")$coalesce)
  # Purity alone does not permit fusion: seq_along depends on call boundaries.
  rducks_register_scalar_udf(con, "bt_sequence", seq_along,
    args = list(DOUBLE), returns = INTEGER, mode = "vectorized")

  # This test-only recorder observes call shape without changing the numerical
  # rowwise function. Production coalesced UDFs must have no side effects.
  fused_lengths <- integer()
  fused <- rducks_register_scalar_udf(con, "bt_fused", function(x) { fused_lengths <<- c(fused_lengths, length(x)); x * 2 },
    args = list(DOUBLE), returns = DOUBLE, mode = "vectorized", coalesce = TRUE)
  expect_true(fused$coalesce)
  expect_true(rducks_explain_udf(con, "bt_fused")$coalesce)
  rducks_register_scalar_udf(con, "bt_point", function(x, y) list(x = x, y = y),
    args = list(DOUBLE, DOUBLE), returns = STRUCT(x = DOUBLE, y = DOUBLE), mode = "vectorized", coalesce = TRUE)
  rducks_register_scalar_udf(con, "bt_blob", function(x) lapply(x, function(v) as.raw(c(0x01, as.integer(v) %% 256L))),
    args = list(DOUBLE), returns = BLOB, mode = "vectorized", coalesce = TRUE)
  rducks_register_scalar_udf(con, "bt_chr", function(s, j) paste0(s, "-", j),
    args = list(VARCHAR, INTEGER), returns = VARCHAR, mode = "vectorized", coalesce = TRUE)
  rducks_register_scalar_udf(con, "bt_throw", function(x) if (any(x > 900000)) stop("boom") else x,
    args = list(DOUBLE), returns = DOUBLE, mode = "vectorized", coalesce = TRUE)
  rducks_register_scalar_udf(con, "bt_special", function(x) ifelse(is.na(x), -1, x),
    args = list(DOUBLE), returns = DOUBLE, mode = "vectorized", null_handling = "special", coalesce = TRUE)
  rducks_register_scalar_udf(con, "bt_return_null", function(x) if (any(x == 0)) stop("sentinel") else x,
    args = list(DOUBLE), returns = DOUBLE, mode = "vectorized", exception_handling = "return_null")

  # Reject requests whose documented call/error semantics cannot be preserved.
  for (flag in list(NA, logical(), c(TRUE, FALSE), 1L)) {
    expect_error(rducks_register_scalar_udf(con, "bt_invalid", identity,
      args = DOUBLE, returns = DOUBLE, mode = "vectorized", coalesce = flag),
      pattern = "coalesce must be TRUE or FALSE")
  }
  expect_error(rducks_register_scalar_udf(con, "bt_invalid", identity,
    args = DOUBLE, returns = DOUBLE, coalesce = TRUE), pattern = "in-process vectorized")
  expect_error(rducks_register_scalar_udf(con, "bt_invalid", identity,
    returns = DOUBLE, mode = "vectorized", coalesce = TRUE), pattern = "explicit, non-empty")
  expect_error(rducks_register_scalar_udf(con, "bt_invalid", identity,
    args = DOUBLE, returns = DOUBLE, mode = "vectorized", side_effects = TRUE, coalesce = TRUE),
    pattern = "side_effects = FALSE")
  expect_error(rducks_register_scalar_udf(con, "bt_invalid", identity,
    args = DOUBLE, returns = DOUBLE, mode = "vectorized", exception_handling = "return_null", coalesce = TRUE),
    pattern = "exception_handling = 'rethrow'")
  expect_error(rducks_register_scalar_udf(con, "bt_invalid", identity,
    args = BIGINT, returns = DOUBLE, mode = "vectorized", coalesce = TRUE), pattern = "plain BOOLEAN")
  # Validate the placement rule without creating IPC workers for an invalid UDF.
  validate <- getFromNamespace("rducks_validate_coalescing", "Rducks")
  expect_error(validate(TRUE, fused$spec, list(marshalling = "wire"), FALSE, "rethrow"),
    pattern = "in-process vectorized")

  # Native registration validates the policy too, including callers using the
  # SQL surface directly. Older bundles without the optional field remain valid.
  make_bundle <- getFromNamespace("rducks_make_rc_vectorized_bundle", "Rducks")
  bundle <- make_bundle(identity, fused$spec, plan = plan)
  native_register <- function(bundle, side_effects = FALSE, exception_handling = "rethrow") {
    put <- getFromNamespace("rducks_evaluator_ref_put", "Rducks")
    remove <- getFromNamespace("rducks_evaluator_ref_remove", "Rducks")
    quote <- getFromNamespace("rducks_sql_string", "Rducks")
    handle <- put(bundle)
    on.exit(remove(handle))
    DBI::dbGetQuery(con, sprintf(
      "SELECT rducks_register_scalar('bt_native_policy', %s, %s, 'f64', 'f64', 'default', %s, %s, 'RCV') AS ok",
      quote(handle$id), quote(handle$token), quote(exception_handling), if (side_effects) "TRUE" else "FALSE"
    ))$ok[[1L]]
  }
  expect_error(native_register(bundle, side_effects = TRUE), pattern = "coalesce = TRUE requires")
  expect_error(native_register(bundle, exception_handling = "return_null"), pattern = "coalesce = TRUE requires")
  bundle$coalesce <- NA
  expect_error(native_register(bundle), pattern = "coalesce must be TRUE or FALSE")
  bundle$coalesce <- NULL
  expect_true(native_register(bundle))

  # Materialized row groups provide concurrent requests for fusion coverage.
  # This does not guarantee progress of legacy DBI's callback-driven queue;
  # run this concurrency test in a subprocess with a timeout.
  DBI::dbExecute(con, "CREATE TABLE src AS SELECT i, CASE WHEN i % 7 = 0 THEN NULL ELSE i * 0.5 END AS v, CASE WHEN i % 11 = 0 THEN NULL ELSE 'v' || i END AS s, (i % 1000)::INTEGER AS j FROM range(1000000) t(i)")
  serial <- list(
    dbl = DBI::dbGetQuery(con, "SELECT i, bt_dbl(v) AS r FROM src ORDER BY i"),
    fused = DBI::dbGetQuery(con, "SELECT i, bt_fused(v) AS r FROM src ORDER BY i"),
    point = DBI::dbGetQuery(con, "SELECT i, bt_point(v, v * 3) AS r FROM src ORDER BY i"),
    blob = DBI::dbGetQuery(con, "SELECT i, bt_blob(v) AS r FROM src ORDER BY i"),
    chr = DBI::dbGetQuery(con, "SELECT i, bt_chr(s, j) AS r FROM src ORDER BY i"),
    special = DBI::dbGetQuery(con, "SELECT i, bt_special(v) AS r FROM src ORDER BY i")
  )
  call_lengths <- integer()
  fused_lengths <- integer()

  rducks_set_execution_plan(con, plan, threads = 8L, external_threads = 1L)
  on.exit(try(rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L), silent = TRUE), add = TRUE)
  concurrent <- list(
    dbl = DBI::dbGetQuery(con, "SELECT i, bt_dbl(v) AS r FROM src ORDER BY i"),
    fused = DBI::dbGetQuery(con, "SELECT i, bt_fused(v) AS r FROM src ORDER BY i"),
    point = DBI::dbGetQuery(con, "SELECT i, bt_point(v, v * 3) AS r FROM src ORDER BY i"),
    blob = DBI::dbGetQuery(con, "SELECT i, bt_blob(v) AS r FROM src ORDER BY i"),
    chr = DBI::dbGetQuery(con, "SELECT i, bt_chr(s, j) AS r FROM src ORDER BY i"),
    special = DBI::dbGetQuery(con, "SELECT i, bt_special(v) AS r FROM src ORDER BY i")
  )
  for (nm in names(serial)) expect_identical(concurrent[[nm]], serial[[nm]], info = nm)
  # Default calls retain one original vector, including side-effectful UDFs.
  expect_true(length(call_lengths) > 0L)
  expect_true(max(call_lengths) <= 2048L, info = sprintf("max default call length %d", max(call_lengths)))
  expect_identical(sum(call_lengths), q1("SELECT count(v)::INTEGER FROM src"))
  expect_true(q1("SELECT max(bt_sequence(v)) FROM src") <= 2048L)
  # Explicit fusion covers multiple original vectors and returns every row.
  expect_true(length(fused_lengths) > 0L)
  expect_true(max(fused_lengths) > 2048L, info = sprintf("max fused call length %d", max(fused_lengths)))
  expect_true(max(fused_lengths) <= 65536L)
  expect_identical(sum(fused_lengths), q1("SELECT count(v)::INTEGER FROM src"))
  # Only the original callback containing the sentinel fails under return_null.
  isolated <- DBI::dbGetQuery(con, paste(
    "SELECT count(*) FILTER (WHERE r IS NULL)::INTEGER AS null_rows,",
    "bool_and(r IS NULL OR r = i) AS values_ok",
    "FROM (SELECT i, bt_return_null(i::DOUBLE) AS r FROM src) s"
  ))
  expect_true(isolated$null_rows[[1L]] > 0L && isolated$null_rows[[1L]] <= 2048L)
  expect_true(isolated$values_ok[[1L]])
  # an error in one coalesced call fails the query, not silently part of it
  expect_error(q1("SELECT sum(bt_throw(i * 1.0)) FROM src"), pattern = "boom|marshal error")
  # counters keep balance after batches
  stats <- rducks_inproc_stats(con)
  expect_identical(stats$pending_current, 0)
  expect_identical(stats$running_current, 0)
  expect_identical(stats$submitted, stats$executed)
})
