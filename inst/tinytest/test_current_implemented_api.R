library(Rducks)

expect_equal(rducks_type_normalize("integer"), "i32")
expect_equal(rducks_duckdb_types(c("i32", "f64", "varchar")), c("INTEGER", "DOUBLE", "VARCHAR"))
expect_equal(rducks_duckdb_signature("f", c("i32", "f64"), "bool"), "f(INTEGER, DOUBLE) -> BOOLEAN")

cb <- rducks_callback(function(x, y) x + y)
expect_inherits(cb, "rducks_callback")
expect_equal(rducks_callback_invoke(cb, list(2, 3)), 5)
rducks_callback_close(cb)

expect_error(rducks_pump(), "not implemented yet")

if (requireNamespace("duckdb", quietly = TRUE) && requireNamespace("DBI", quietly = TRUE)) {
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con)
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_version() AS x")$x, "Rducks extension loaded")

  reg1 <- rducks_register(con, "rducks_plus_one", function(x) x + 1, "f64", "f64")
  expect_inherits(reg1, "rducks_registration")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_plus_one(41.0) AS x")$x, 42)

  reg2 <- rducks_register(con, "rducks_add", function(x, y) x + y, c("f64", "f64"), "f64")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_add(1.5, 2.25) AS x")$x, 3.75)
}
