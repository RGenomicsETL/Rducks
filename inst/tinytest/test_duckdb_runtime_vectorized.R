library(Rducks)

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  calls <- 0L
  sizes <- integer()
  invisible(rducks_register(
    con, "vec_plus_one",
    function(x) {
      calls <<- calls + 1L
      sizes <<- c(sizes, length(x))
      x + 1
    },
    DOUBLE, DOUBLE,
    mode = "vectorized",
    side_effects = TRUE
  ))

  n <- 5000L
  got <- DBI::dbGetQuery(con, sprintf(
    "SELECT sum(vec_plus_one(i::DOUBLE)) AS x FROM range(%d) AS t(i)",
    n
  ))
  expect_equal(got$x, sum((0:(n - 1L)) + 1))
  expect_true(calls >= 1L)
  expect_true(calls < n)
  expect_equal(sum(sizes), n)
  expect_true(max(sizes) > 1L)

  invisible(rducks_register(con, "vec_conf_row_default", function(x) x + 1L,
                            INTEGER, INTEGER, side_effects = TRUE))
  invisible(rducks_register(con, "vec_conf_chunk_default", function(x) x + 1L,
                            INTEGER, INTEGER, mode = "vectorized", side_effects = TRUE))
  conf_default <- DBI::dbGetQuery(con, paste(
    "WITH t(x) AS (VALUES (1::INTEGER), (NULL::INTEGER), (3::INTEGER))",
    "SELECT bool_and(vec_conf_chunk_default(x) IS NOT DISTINCT FROM vec_conf_row_default(x)) AS ok FROM t"
  ))
  expect_true(conf_default$ok[[1L]])

  invisible(rducks_register(con, "vec_conf_row_special",
                            function(x) if (is.na(x)) 99L else x + 1L,
                            INTEGER, INTEGER, null_handling = "special", side_effects = TRUE))
  invisible(rducks_register(con, "vec_conf_chunk_special",
                            function(x) ifelse(is.na(x), 99L, x + 1L),
                            INTEGER, INTEGER, mode = "vectorized", null_handling = "special", side_effects = TRUE))
  conf_special <- DBI::dbGetQuery(con, paste(
    "WITH t(x) AS (VALUES (1::INTEGER), (NULL::INTEGER), (3::INTEGER))",
    "SELECT bool_and(vec_conf_chunk_special(x) IS NOT DISTINCT FROM vec_conf_row_special(x)) AS ok FROM t"
  ))
  expect_true(conf_special$ok[[1L]])

  seen_default <- list()
  invisible(rducks_register(
    con, "vec_default_null",
    function(x) {
      seen_default[[length(seen_default) + 1L]] <<- x
      x + 10L
    },
    INTEGER, INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  ))
  default_null <- DBI::dbGetQuery(con, paste(
    "WITH t(i, x) AS (VALUES (1, 1::INTEGER), (2, NULL::INTEGER), (3, 3::INTEGER))",
    "SELECT i, vec_default_null(x) AS y FROM t ORDER BY i"
  ))
  expect_equal(default_null$y, c(11L, NA_integer_, 13L))
  expect_equal(length(seen_default), 1L)
  expect_equal(seen_default[[1L]], c(1L, 3L))

  calls_all_null <- 0L
  invisible(rducks_register(
    con, "vec_all_null_default",
    function(x) {
      calls_all_null <<- calls_all_null + 1L
      x
    },
    INTEGER, INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  ))
  all_null <- DBI::dbGetQuery(con, paste(
    "WITH t(i, x) AS (VALUES (1, NULL::INTEGER), (2, NULL::INTEGER))",
    "SELECT i, vec_all_null_default(x) AS y FROM t ORDER BY i"
  ))
  expect_equal(all_null$y, c(NA_integer_, NA_integer_))
  expect_equal(calls_all_null, 0L)

  seen_special <- list()
  invisible(rducks_register(
    con, "vec_special_null",
    function(x) {
      seen_special[[length(seen_special) + 1L]] <<- x
      ifelse(is.na(x), 5L, x)
    },
    INTEGER, INTEGER,
    mode = "vectorized",
    null_handling = "special",
    side_effects = TRUE
  ))
  special_null <- DBI::dbGetQuery(con, paste(
    "WITH t(i, x) AS (VALUES (1, 1::INTEGER), (2, NULL::INTEGER), (3, 3::INTEGER))",
    "SELECT i, vec_special_null(x) AS y FROM t ORDER BY i"
  ))
  expect_equal(special_null$y, c(1L, 5L, 3L))
  expect_equal(length(seen_special), 1L)
  expect_equal(seen_special[[1L]], c(1L, NA_integer_, 3L))

  invisible(rducks_register(con, "vec_scalar_null_return", function(x) NULL,
                            INTEGER, INTEGER, null_handling = "special", side_effects = TRUE))
  invisible(rducks_register(con, "vec_chunk_null_return", function(x) vector("list", length(x)),
                            INTEGER, INTEGER, mode = "vectorized", null_handling = "special", side_effects = TRUE))
  null_return <- DBI::dbGetQuery(con, paste(
    "WITH t(i, x) AS (VALUES (1, 1::INTEGER), (2, NULL::INTEGER), (3, 3::INTEGER))",
    "SELECT i, vec_scalar_null_return(x) AS row_y, vec_chunk_null_return(x) AS chunk_y FROM t ORDER BY i"
  ))
  expect_equal(null_return$row_y, c(NA_integer_, NA_integer_, NA_integer_))
  expect_equal(null_return$chunk_y, c(NA_integer_, NA_integer_, NA_integer_))

  invisible(rducks_register(
    con, "vec_bad_length",
    function(x) x[1L],
    INTEGER, INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  ))
  expect_error(
    DBI::dbGetQuery(con, "SELECT vec_bad_length(i::INTEGER) AS x FROM range(3) AS t(i)"),
    "vectorized return value must have length"
  )

  rducks_set_execution_plan(con, rducks_execution_plan("arrow_c", "serial"))
  expect_error(
    rducks_register(con, "vec_arrow_c_rejected", function(x) x, INTEGER, INTEGER,
                    mode = "vectorized"),
    "does not support mode = 'vectorized'"
  )
  rducks_set_execution_plan(con, rducks_execution_plan("arrow_r", "serial"))
  expect_error(
    rducks_register(con, "vec_no_arg_rejected", function() 1L, character(), INTEGER,
                    mode = "vectorized"),
    "at least one declared argument"
  )
})
