library(Rducks)

local({
  if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE)) {
    exit_file("duckdb/DBI not available")
  }
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  on.exit(rducks_release(con), add = TRUE)

  rducks_register_scalar_udf(con, "rducks_direct_plus1", function(x) x + 1L,
    args = list(INTEGER), returns = INTEGER)
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_direct_plus1(41::INTEGER) AS x")$x, 42L)
})
