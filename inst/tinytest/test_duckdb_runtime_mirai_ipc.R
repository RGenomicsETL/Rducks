library(Rducks)

if (requireNamespace("mirai", quietly = TRUE) &&
    requireNamespace("duckdb", quietly = TRUE) &&
    requireNamespace("DBI", quietly = TRUE)) {
  local({
    con <- DBI::dbConnect(
      duckdb::duckdb(config = list(allow_unsigned_extensions = "true")),
      dbdir = ":memory:"
    )
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    rducks_enable(con, threads = "single")

    plan <- rducks_execution_plan(
      "arrow_ipc", "multiprocess_parallel",
      ipc_provider = "mirai",
      ipc_workers = 1L,
      future_timeout = 30
    )
    expect_equal(plan$engine_id, "ipc_mirai_pool")
    rducks_set_execution_plan(con, plan)

    reg <- rducks_register(
      con,
      "mirai_ipc_plus_one",
      function(x) x + 1L,
      INTEGER,
      INTEGER,
      mode = "vectorized",
      side_effects = TRUE
    )
    expect_equal(reg$execution_plan$engine_id, "ipc_mirai_pool")

    out <- DBI::dbGetQuery(con, "SELECT mirai_ipc_plus_one(i::INTEGER) AS x FROM range(5) AS t(i)")
    expect_equal(out$x, 1:5)

    explain <- rducks_explain_udf(con, "mirai_ipc_plus_one")
    expect_equal(explain$evaluator, "RIPC")
    expect_equal(explain$engine_id, "ipc_mirai_pool")
    expect_equal(explain$marshalling, "arrow_ipc")
    expect_true(explain$arrow_ipc_chunks >= 1)
    expect_equal(explain$arrow_r_chunks, 0)
    expect_equal(explain$arrow_c_chunks, 0)
  })
}
