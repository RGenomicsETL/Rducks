library(Rducks)

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  invisible(rducks_register_scalar_udf(con, "rducks_list_len", function(x) length(x) + as.integer(is.integer(x)), INTEGER[], INTEGER))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_list_len([1,2,3]::INTEGER[]) AS x")$x, 4L)

  invisible(rducks_register_scalar_udf(con, "rducks_array_sum", function(x) sum(x), INTEGER[3], INTEGER))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_array_sum([1,2,3]::INTEGER[3]) AS x")$x, 6L)

  invisible(rducks_register_scalar_udf(con, "rducks_list_null", function(x) as.integer(is.na(x[[2L]])), INTEGER[], INTEGER, null_handling = "special"))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_list_null([1,NULL,3]::INTEGER[]) AS x")$x, 1L)

  invisible(rducks_register_scalar_udf(con, "rducks_struct_sum", function(x) x$a + x$b, STRUCT(a = INTEGER, b = INTEGER), INTEGER))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_struct_sum({'a': 20, 'b': 22}::STRUCT(a INTEGER, b INTEGER)) AS x")$x, 42L)

  invisible(rducks_register_scalar_udf(con, "rducks_map_sum", function(x) sum(x$values), MAP(VARCHAR, INTEGER), INTEGER))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_map_sum(map(['a','b'], [20,22])) AS x")$x, 42L)

  invisible(rducks_register_scalar_udf(con, "rducks_nested_len", function(x) length(x$s) + as.integer(is.integer(x$s)), STRUCT(s = INTEGER[]), INTEGER))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_nested_len({'s': [1,2,3]}::STRUCT(s INTEGER[])) AS x")$x, 4L)

  invisible(rducks_register_scalar_udf(con, "rducks_make_struct", function(x) list(a = x, b = x + 1L), INTEGER, STRUCT(a = INTEGER, b = INTEGER)))
  expect_equal(DBI::dbGetQuery(con, "SELECT (rducks_make_struct(41::INTEGER)).b AS x")$x, 42L)

  invisible(rducks_register_scalar_udf(con, "rducks_make_list", function(x) c(x, x + 1L), INTEGER, INTEGER[]))
  expect_equal(DBI::dbGetQuery(con, "SELECT list_sum(rducks_make_list(20::INTEGER)) AS x")$x, 41)

  invisible(rducks_register_scalar_udf(con, "rducks_make_map", function(x) list(keys = c('a', 'b'), values = c(x, x + 1L)), INTEGER, MAP(VARCHAR, INTEGER)))
  expect_equal(DBI::dbGetQuery(con, "SELECT list_sum(map_values(rducks_make_map(20::INTEGER))) AS x")$x, 41)

  invisible(rducks_register_scalar_udf(con, "rducks_list_return", function() c(1L, 2L), character(), INTEGER[]))
  expect_equal(DBI::dbGetQuery(con, "SELECT list_sum(rducks_list_return()) AS x")$x, 3)
  invisible(rducks_register_scalar_udf(con, "rducks_bigint_array_bad", function() c(1, 2), character(), BIGINT[2]))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_bigint_array_bad() AS x"), "marshal")

  many_args <- rep("f64", 20)
  invisible(rducks_register_scalar_udf(con, "rducks_sum20", function(...) sum(unlist(list(...))), many_args, "f64"))
  sum20_sql <- paste(rep("1.0", 20), collapse = ", ")
  expect_equal(DBI::dbGetQuery(con, sprintf("SELECT rducks_sum20(%s) AS x", sum20_sql))$x, 20)

  invisible(rducks_register_scalar_udf(con, "rducks_tmp", function(x) x + 10, "f64", "f64"))
  gc()
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_tmp(32.0) AS x")$x, 42)

  rducks_set_execution_plan(con, rducks_execution_plan("arrow_c", "serial"))
  invisible(rducks_register_scalar_udf(con, "rducks_list_sum_arrow_c", function(x) sum(x), INTEGER[], INTEGER))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_list_sum_arrow_c([20,22]::INTEGER[]) AS x")$x, 42L)
  list_explain <- rducks_explain_udf(con, "rducks_list_sum_arrow_c")
  expect_equal(list_explain$evaluator, "RC")
  expect_true(list_explain$arrow_c_chunks >= 1)
  expect_equal(list_explain$arrow_r_chunks, 0)

  invisible(rducks_register_scalar_udf(con, "rducks_array_make_arrow_c", function(x) c(x, x + 1L, x + 2L), INTEGER, INTEGER[3]))
  expect_equal(DBI::dbGetQuery(con, "SELECT list_sum(rducks_array_make_arrow_c(13::INTEGER)) AS x")$x, 42L)
  array_explain <- rducks_explain_udf(con, "rducks_array_make_arrow_c")
  expect_equal(array_explain$evaluator, "RC")
  expect_true(array_explain$arrow_c_chunks >= 1)
  expect_equal(array_explain$arrow_r_chunks, 0)

  invisible(rducks_register_scalar_udf(con, "rducks_struct_sum_arrow_c", function(x) x$a + x$b, STRUCT(a = INTEGER, b = INTEGER), INTEGER))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_struct_sum_arrow_c({'a': 20, 'b': 22}::STRUCT(a INTEGER, b INTEGER)) AS x")$x, 42L)
  struct_in_explain <- rducks_explain_udf(con, "rducks_struct_sum_arrow_c")
  expect_equal(struct_in_explain$evaluator, "RC")
  expect_true(struct_in_explain$arrow_c_chunks >= 1)
  expect_equal(struct_in_explain$arrow_r_chunks, 0)

  invisible(rducks_register_scalar_udf(con, "rducks_struct_make_arrow_c", function(x) list(a = x, b = x + 1L), INTEGER, STRUCT(a = INTEGER, b = INTEGER)))
  expect_equal(DBI::dbGetQuery(con, "SELECT (rducks_struct_make_arrow_c(41::INTEGER)).b AS x")$x, 42L)
  struct_out_explain <- rducks_explain_udf(con, "rducks_struct_make_arrow_c")
  expect_equal(struct_out_explain$evaluator, "RC")
  expect_true(struct_out_explain$arrow_c_chunks >= 1)
  expect_equal(struct_out_explain$arrow_r_chunks, 0)

  invisible(rducks_register_scalar_udf(con, "rducks_map_sum_arrow_c", function(x) sum(x$values), MAP(VARCHAR, INTEGER), INTEGER))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_map_sum_arrow_c(map(['a','b'], [20,22])) AS x")$x, 42L)
  map_in_explain <- rducks_explain_udf(con, "rducks_map_sum_arrow_c")
  expect_equal(map_in_explain$evaluator, "RC")
  expect_true(map_in_explain$arrow_c_chunks >= 1)
  expect_equal(map_in_explain$arrow_r_chunks, 0)

  invisible(rducks_register_scalar_udf(con, "rducks_map_make_arrow_c", function(x) list(keys = c('a', 'b'), values = c(x, x + 1L)), INTEGER, MAP(VARCHAR, INTEGER)))
  expect_equal(DBI::dbGetQuery(con, "SELECT list_sum(map_values(rducks_map_make_arrow_c(20::INTEGER))) AS x")$x, 41L)
  map_out_explain <- rducks_explain_udf(con, "rducks_map_make_arrow_c")
  expect_equal(map_out_explain$evaluator, "RC")
  expect_true(map_out_explain$arrow_c_chunks >= 1)
  expect_equal(map_out_explain$arrow_r_chunks, 0)

  invisible(rducks_register_scalar_udf(con, "rducks_map_null_key_arrow_c", function() list(keys = c('a', NA_character_), values = c(1L, 2L)), character(), MAP(VARCHAR, INTEGER)))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_map_null_key_arrow_c() AS x"), "MAP keys must not be NULL")
  invisible(rducks_register_scalar_udf(con, "rducks_map_duplicate_key_arrow_c", function() list(keys = c('a', 'a'), values = c(1L, 2L)), character(), MAP(VARCHAR, INTEGER)))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_map_duplicate_key_arrow_c() AS x"), "MAP keys must be unique")
})
