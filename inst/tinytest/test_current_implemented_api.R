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
  rducks_enable(con, threads = "single")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_version() AS x")$x, "Rducks extension loaded")

  reg1 <- rducks_register(con, "rducks_plus_one", function(x) x + 1, "f64", "f64")
  expect_inherits(reg1, "rducks_registration")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_plus_one(41.0) AS x")$x, 42)

  reg2 <- rducks_register(con, "rducks_add", function(x, y) x + y, c("f64", "f64"), "f64")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_add(1.5, 2.25) AS x")$x, 3.75)

  reg3 <- rducks_register(con, "rducks_i32_double", function(x) as.integer(x * 2L), "i32", "i32")
  expect_inherits(reg3$compiled, "rducks_compiled_wrapper")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_i32_double(21::INTEGER) AS x")$x, 42L)

  reg4 <- rducks_register(con, "rducks_not", function(x) !x, "bool", "bool")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_not(TRUE) AS x")$x, FALSE)

  reg5 <- rducks_register(con, "rducks_greet", function(x) paste0('hi ', x), "varchar", "varchar")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_greet('duck') AS x")$x, "hi duck")

  invisible(rducks_register(con, "rducks_null_default", function(x) stop("should not be called"), "i32", "i32"))
  expect_true(is.na(DBI::dbGetQuery(con, "SELECT rducks_null_default(NULL::INTEGER) AS x")$x))

  invisible(rducks_register(
    con, "rducks_null_special", function(x) if (is.na(x)) 5L else x, "i32", "i32",
    null_handling = "special"
  ))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_null_special(NULL::INTEGER) AS x")$x, 5L)

  invisible(rducks_register(
    con, "rducks_error_null", function(x) stop("boom"), "i32", "i32",
    exception_handling = "return_null"
  ))
  expect_true(is.na(DBI::dbGetQuery(con, "SELECT rducks_error_null(1::INTEGER) AS x")$x))

  counter <- local({
    i <- 0L
    function() {
      i <<- i + 1L
      i
    }
  })
  invisible(rducks_register(con, "rducks_counter", counter, character(), "i32", side_effects = TRUE))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_counter() AS x FROM range(5)")$x, 1:5)

  many_args <- rep("f64", 20)
  invisible(rducks_register(con, "rducks_sum20", function(...) sum(unlist(list(...))), many_args, "f64"))
  sum20_sql <- paste(rep("1.0", 20), collapse = ", ")
  expect_equal(DBI::dbGetQuery(con, sprintf("SELECT rducks_sum20(%s) AS x", sum20_sql))$x, 20)

  invisible(rducks_register(con, "rducks_tmp", function(x) x + 10, "f64", "f64"))
  gc()
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_tmp(32.0) AS x")$x, 42)
}
