library(Rducks)

# Dynamic (omitted-args) scalar UDFs on the worker-process (ipc) transport.
# DuckDB resolves the concrete argument types per call site at bind; the native
# bind carries those resolved types to the worker in the RDT1 dynamic payload, so
# one registration serves call sites with different argument types. Gated like
# the other worker-process tests (spawns mirai daemons).
if (!identical(tolower(Sys.getenv("RDUCKS_RUN_IPC_TESTS", "")), "true")) {
  exit_file("ipc dynamic-args test disabled (set RDUCKS_RUN_IPC_TESTS=true)")
}
if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE) ||
    !requireNamespace("mirai", quietly = TRUE) || !requireNamespace("nanonext", quietly = TRUE)) {
  exit_file("ipc dependencies not available")
}

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  on.exit(rducks_release(con), add = TRUE)

  plan <- rducks_execution_plan("ipc", ipc_workers = 2L, ipc_timeout = 60)

  # Register a dynamic UDF (no `args`) under the ipc plan, single-threaded so the
  # closure is broadcast to the workers. The return type is fixed (VARCHAR) while
  # the argument type varies per call site.
  rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
  reg <- rducks_register_scalar_udf(con, "r_dyn_show", function(x) paste0("got:", x), returns = VARCHAR)
  expect_true(isTRUE(reg$spec$dynamic_args), info = "registered as a dynamic (omitted-args) UDF")

  # Raise DuckDB threads so callbacks fan out to the worker pool.
  rducks_set_execution_plan(con, plan, threads = 3L, external_threads = 2L)

  # Same UDF, different concrete argument type at each call site -> the worker
  # materializes each under the bind-resolved type.
  expect_equal(DBI::dbGetQuery(con, "SELECT r_dyn_show(42::INTEGER) AS v")$v, "got:42",
               info = "dynamic ipc UDF over an INTEGER call site")
  expect_equal(DBI::dbGetQuery(con, "SELECT r_dyn_show(2.5::DOUBLE) AS v")$v, "got:2.5",
               info = "dynamic ipc UDF over a DOUBLE call site")
  expect_equal(DBI::dbGetQuery(con, "SELECT r_dyn_show('hi'::VARCHAR) AS v")$v, "got:hi",
               info = "dynamic ipc UDF over a VARCHAR call site")

  # A whole column with a SQL NULL mixed in (default NULL handling -> NULL passes
  # through without calling R).
  got <- DBI::dbGetQuery(con, "
    SELECT i, r_dyn_show(v) AS shown
    FROM (VALUES (1, 10::INTEGER), (2, NULL::INTEGER), (3, 30::INTEGER)) t(i, v)
    ORDER BY i")
  expect_equal(got$shown, c("got:10", NA, "got:30"),
               info = "dynamic ipc UDF over an INTEGER column with a NULL")

  # A two-argument dynamic UDF, resolved per call site.
  rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
  rducks_register_scalar_udf(con, "r_dyn_concat", function(a, b) paste(a, b, sep = "|"), returns = VARCHAR)
  rducks_set_execution_plan(con, plan, threads = 3L, external_threads = 2L)
  expect_equal(DBI::dbGetQuery(con, "SELECT r_dyn_concat(7::INTEGER, 'x'::VARCHAR) AS v")$v, "7|x",
               info = "two-argument dynamic ipc UDF with mixed concrete types")
})
