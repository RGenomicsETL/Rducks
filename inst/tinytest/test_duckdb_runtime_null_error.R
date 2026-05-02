library(Rducks)

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  invisible(rducks_register(con, "rducks_null_default", function(x) stop("should not be called"), "i32", "i32"))
  expect_true(is.na(DBI::dbGetQuery(con, "SELECT rducks_null_default(NULL::INTEGER) AS x")$x))

  invisible(rducks_register(
    con, "rducks_null_special", function(x) if (is.na(x)) 5L else x, "i32", "i32",
    null_handling = "special"
  ))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_null_special(NULL::INTEGER) AS x")$x, 5L)

  invisible(rducks_register(
    con, "rducks_null_special_bigint", function(x) as.integer(is.null(x)), BIGINT, INTEGER,
    null_handling = "special"
  ))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_null_special_bigint(NULL::BIGINT) AS x")$x, 1L)

  invisible(rducks_register(
    con, "rducks_null_special_blob", function(x) as.integer(is.null(x)), BLOB, INTEGER,
    null_handling = "special"
  ))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_null_special_blob(NULL::BLOB) AS x")$x, 1L)

  invisible(rducks_register(
    con, "rducks_error_null", function(x) stop("boom"), "i32", "i32",
    exception_handling = "return_null"
  ))
  expect_true(is.na(DBI::dbGetQuery(con, "SELECT rducks_error_null(1::INTEGER) AS x")$x))

  invisible(rducks_register(con, "rducks_i32_na_return", function() NA_integer_, character(), INTEGER))
  expect_true(is.na(DBI::dbGetQuery(con, "SELECT rducks_i32_na_return() AS x")$x))
  invisible(rducks_register(con, "rducks_i32_nan_bad", function() NaN, character(), INTEGER))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_i32_nan_bad() AS x"), "Rducks")
  invisible(rducks_register(con, "rducks_i32_inf_bad", function() Inf, character(), INTEGER))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_i32_inf_bad() AS x"), "Rducks")
  invisible(rducks_register(con, "rducks_i32_fraction_bad", function() 1.5, character(), INTEGER))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_i32_fraction_bad() AS x"), "Rducks")
  invisible(rducks_register(con, "rducks_i32_length_bad", function() c(1L, 2L), character(), INTEGER))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_i32_length_bad() AS x"), "length 1")
  invisible(rducks_register(con, "rducks_i32_empty_bad", function() integer(), character(), INTEGER))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_i32_empty_bad() AS x"), "length 1")
  invisible(rducks_register(con, "rducks_struct_i32_nan_bad", function() list(a = NaN), character(), STRUCT(a = INTEGER)))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_struct_i32_nan_bad() AS x"), "marshal")
  invisible(rducks_register(con, "rducks_double_inf_return", function() Inf, character(), DOUBLE))
  expect_true(is.infinite(DBI::dbGetQuery(con, "SELECT rducks_double_inf_return() AS x")$x))
  invisible(rducks_register(con, "rducks_double_nan_return", function() NaN, character(), DOUBLE))
  expect_true(is.nan(DBI::dbGetQuery(con, "SELECT rducks_double_nan_return() AS x")$x))
  suppressWarnings(invisible(rducks_register(con, "rducks_float_inf_return", function() Inf, character(), FLOAT)))
  expect_true(is.infinite(DBI::dbGetQuery(con, "SELECT rducks_float_inf_return() AS x")$x))

  counter <- local({
    i <- 0L
    function() {
      i <<- i + 1L
      i
    }
  })
  invisible(rducks_register(con, "rducks_counter", counter, character(), "i32", side_effects = TRUE))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_counter() AS x FROM range(5)")$x, 1:5)
})
