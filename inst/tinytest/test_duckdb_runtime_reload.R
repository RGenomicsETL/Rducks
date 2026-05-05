library(Rducks)

for (i in seq_len(12L)) local({
  con <- DBI::dbConnect(
    duckdb::duckdb(config = list(allow_unsigned_extensions = "true")),
    dbdir = ":memory:"
  )
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  expect_equal(
    DBI::dbGetQuery(con, "SELECT rducks_version() AS v")$v[[1L]],
    "Rducks extension loaded"
  )
})
