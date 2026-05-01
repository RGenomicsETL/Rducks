library(Rducks)

if (requireNamespace("duckdb", quietly = TRUE) && requireNamespace("DBI", quietly = TRUE)) {
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")


  reg1 <- rducks_register(con, "rducks_plus_one", function(x) x + 1, DOUBLE, DOUBLE)
  expect_inherits(reg1, "rducks_registration")
  expect_equal(reg1$spec$mode, "row")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_plus_one(41.0) AS x")$x, 42)
  DBI::dbExecute(con, "PRAGMA threads=4")
  expect_equal(
    as.numeric(DBI::dbGetQuery(con, "SELECT sum(rducks_plus_one((i % 100)::DOUBLE)) AS x FROM range(50000) t(i)")$x),
    2525000
  )
  DBI::dbExecute(con, "PRAGMA threads=1")

  reg_soft <- rducks_register(con, "rducks_soft_unregister", function(x) x + 1L, INTEGER, INTEGER)
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_soft_unregister(1::INTEGER) AS x")$x, 2L)
  expect_null(rducks_unregister(reg_soft))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_soft_unregister(1::INTEGER) AS x"), "unregistered")
  invisible(rducks_register(con, "rducks_soft_unregister", function(x) x + 2L, INTEGER, INTEGER))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_soft_unregister(1::INTEGER) AS x")$x, 3L)

  reg2 <- rducks_register(con, "rducks_add", function(x, y) x + y, c(DOUBLE, DOUBLE), DOUBLE)
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_add(1.5, 2.25) AS x")$x, 3.75)

  reg3 <- rducks_register(con, "rducks_i32_double", function(x) as.integer(x * 2L), "i32", "i32")
  expect_inherits(reg3$callback, "rducks_callback")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_i32_double(21::INTEGER) AS x")$x, 42L)

  reg4 <- rducks_register(con, "rducks_not", function(x) !x, "bool", "bool")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_not(TRUE) AS x")$x, FALSE)

  reg5 <- rducks_register(con, "rducks_greet", function(x) paste0('hi ', x), "varchar", "varchar")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_greet('duck') AS x")$x, "hi duck")
}
