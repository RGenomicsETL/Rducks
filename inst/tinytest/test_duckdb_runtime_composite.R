library(Rducks)

if (requireNamespace("duckdb", quietly = TRUE) && requireNamespace("DBI", quietly = TRUE)) {
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  invisible(rducks_register(con, "rducks_list_len", function(x) length(x) + as.integer(is.integer(x)), INTEGER[], INTEGER))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_list_len([1,2,3]::INTEGER[]) AS x")$x, 4L)

  invisible(rducks_register(con, "rducks_array_sum", function(x) sum(x), INTEGER[3], INTEGER))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_array_sum([1,2,3]::INTEGER[3]) AS x")$x, 6L)

  invisible(rducks_register(con, "rducks_list_null", function(x) as.integer(is.na(x[[2L]])), INTEGER[], INTEGER, null_handling = "special"))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_list_null([1,NULL,3]::INTEGER[]) AS x")$x, 1L)

  invisible(rducks_register(con, "rducks_struct_sum", function(x) x$a + x$b, STRUCT(a = INTEGER, b = INTEGER), INTEGER))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_struct_sum({'a': 20, 'b': 22}::STRUCT(a INTEGER, b INTEGER)) AS x")$x, 42L)

  invisible(rducks_register(con, "rducks_map_sum", function(x) sum(x$values), MAP(VARCHAR, INTEGER), INTEGER))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_map_sum(map(['a','b'], [20,22])) AS x")$x, 42L)

  invisible(rducks_register(con, "rducks_nested_len", function(x) length(x$s) + as.integer(is.integer(x$s)), STRUCT(s = INTEGER[]), INTEGER))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_nested_len({'s': [1,2,3]}::STRUCT(s INTEGER[])) AS x")$x, 4L)

  invisible(rducks_register(con, "rducks_make_struct", function(x) list(a = x, b = x + 1L), INTEGER, STRUCT(a = INTEGER, b = INTEGER)))
  expect_equal(DBI::dbGetQuery(con, "SELECT (rducks_make_struct(41::INTEGER)).b AS x")$x, 42L)

  invisible(rducks_register(con, "rducks_make_list", function(x) c(x, x + 1L), INTEGER, INTEGER[]))
  expect_equal(DBI::dbGetQuery(con, "SELECT list_sum(rducks_make_list(20::INTEGER)) AS x")$x, 41)

  invisible(rducks_register(con, "rducks_make_map", function(x) list(keys = c('a', 'b'), values = c(x, x + 1L)), INTEGER, MAP(VARCHAR, INTEGER)))
  expect_equal(DBI::dbGetQuery(con, "SELECT list_sum(map_values(rducks_make_map(20::INTEGER))) AS x")$x, 41)

  invisible(rducks_register(con, "rducks_list_return", function() c(1L, 2L), character(), INTEGER[]))
  expect_equal(DBI::dbGetQuery(con, "SELECT list_sum(rducks_list_return()) AS x")$x, 3)
  invisible(rducks_register(con, "rducks_bigint_array_bad", function() c(1, 2), character(), BIGINT[2]))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_bigint_array_bad() AS x"), "marshal")

  many_args <- rep("f64", 20)
  invisible(rducks_register(con, "rducks_sum20", function(...) sum(unlist(list(...))), many_args, "f64"))
  sum20_sql <- paste(rep("1.0", 20), collapse = ", ")
  expect_equal(DBI::dbGetQuery(con, sprintf("SELECT rducks_sum20(%s) AS x", sum20_sql))$x, 20)

  invisible(rducks_register(con, "rducks_tmp", function(x) x + 10, "f64", "f64"))
  gc()
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_tmp(32.0) AS x")$x, 42)
}
