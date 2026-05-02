library(Rducks)

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  register_pair <- function(base, fun, args, returns, ..., side_effects = TRUE) {
    invisible(rducks_register(con, paste0(base, "_r"), fun, args, returns, ..., eval_mode = "R", side_effects = side_effects))
    invisible(rducks_register(con, paste0(base, "_rc"), fun, args, returns, ..., eval_mode = "RC", side_effects = side_effects))
  }

  expect_pair_equal <- function(sql) {
    out <- DBI::dbGetQuery(con, sql)
    expect_equal(out$r, out$rc)
  }

  register_pair("eval_i32", function(x) x + 1L, INTEGER, INTEGER)
  expect_pair_equal("SELECT eval_i32_r(i::INTEGER) AS r, eval_i32_rc(i::INTEGER) AS rc FROM range(20) t(i)")

  register_pair("eval_f64", function(x, y) x * 2 + y, c(DOUBLE, DOUBLE), DOUBLE)
  expect_pair_equal("SELECT eval_f64_r(i::DOUBLE, 0.5::DOUBLE) AS r, eval_f64_rc(i::DOUBLE, 0.5::DOUBLE) AS rc FROM range(20) t(i)")

  register_pair("eval_varchar", function(x) paste0(x, ":", nchar(x)), VARCHAR, VARCHAR)
  expect_pair_equal("SELECT eval_varchar_r(x) AS r, eval_varchar_rc(x) AS rc FROM (VALUES ('a'), ('duck'), ('R')) t(x)")

  register_pair("eval_blob", function(x) c(x, as.raw(0xff)), BLOB, BLOB)
  expect_pair_equal("SELECT hex(eval_blob_r(x)) AS r, hex(eval_blob_rc(x)) AS rc FROM (VALUES (from_hex('00AA')), (from_hex('10'))) t(x)")

  register_pair("eval_date", function(x) x + 1, DATE, DATE)
  expect_pair_equal("SELECT eval_date_r(x)::VARCHAR AS r, eval_date_rc(x)::VARCHAR AS rc FROM (VALUES (DATE '2020-01-02'), (DATE '1970-01-01')) t(x)")

  register_pair("eval_time", function(x) x + 1, TIME, TIME)
  expect_pair_equal("SELECT eval_time_r(x)::VARCHAR AS r, eval_time_rc(x)::VARCHAR AS rc FROM (VALUES (TIME '01:02:03'), (TIME '23:59:58')) t(x)")

  register_pair("eval_timestamp", function(x) x + 1, TIMESTAMP, TIMESTAMP)
  expect_pair_equal("SELECT eval_timestamp_r(x)::VARCHAR AS r, eval_timestamp_rc(x)::VARCHAR AS rc FROM (VALUES (TIMESTAMP '2020-01-02 03:04:05'), (TIMESTAMP '1970-01-01 00:00:00')) t(x)")

  register_pair("eval_decimal", function(x) x + rducks_decimal("1.25", 10, 2), DECIMAL(10, 2), DECIMAL(10, 2))
  expect_pair_equal("SELECT eval_decimal_r(x)::VARCHAR AS r, eval_decimal_rc(x)::VARCHAR AS rc FROM (VALUES (1.25::DECIMAL(10,2)), (2.50::DECIMAL(10,2))) t(x)")

  register_pair("eval_list", function(x) sum(x), INTEGER[], INTEGER)
  expect_pair_equal("SELECT eval_list_r(x) AS r, eval_list_rc(x) AS rc FROM (VALUES ([1,2,3]::INTEGER[]), ([4,5]::INTEGER[])) t(x)")

  register_pair("eval_struct", function(x) x$a + x$b, STRUCT(a = INTEGER, b = INTEGER), INTEGER)
  expect_pair_equal("SELECT eval_struct_r(x) AS r, eval_struct_rc(x) AS rc FROM (VALUES ({'a': 20, 'b': 22}::STRUCT(a INTEGER, b INTEGER)), ({'a': 1, 'b': 2}::STRUCT(a INTEGER, b INTEGER))) t(x)")

  register_pair("eval_map", function(x) sum(x$values), MAP(VARCHAR, INTEGER), INTEGER)
  expect_pair_equal("SELECT eval_map_r(x) AS r, eval_map_rc(x) AS rc FROM (VALUES (map(['a','b'], [20,22])), (map(['a','b'], [1,2]))) t(x)")

  register_pair("eval_enum", function(x) x, ENUM(c("red", "blue")), ENUM(c("red", "blue")))
  expect_pair_equal("SELECT eval_enum_r(x)::VARCHAR AS r, eval_enum_rc(x)::VARCHAR AS rc FROM (VALUES ('red'::ENUM('red','blue')), ('blue'::ENUM('red','blue'))) t(x)")

  register_pair(
    "eval_union",
    function(x) if (identical(x$tag, "code")) rducks_union("label", paste0("c", x$value)) else rducks_union("code", 1L),
    UNION(code = INTEGER, label = VARCHAR),
    UNION(code = INTEGER, label = VARCHAR)
  )
  expect_pair_equal("SELECT union_extract(eval_union_r(x), 'label') AS r, union_extract(eval_union_rc(x), 'label') AS rc FROM (SELECT union_value(code := 42)::UNION(code INTEGER, label VARCHAR) AS x)")

  calls_default_r <- 0L
  calls_default_rc <- 0L
  invisible(rducks_register(con, "eval_null_default_r", function(x) { calls_default_r <<- calls_default_r + 1L; x }, INTEGER, INTEGER, eval_mode = "R", side_effects = TRUE))
  invisible(rducks_register(con, "eval_null_default_rc", function(x) { calls_default_rc <<- calls_default_rc + 1L; x }, INTEGER, INTEGER, eval_mode = "RC", side_effects = TRUE))
  expect_pair_equal("SELECT eval_null_default_r(x) AS r, eval_null_default_rc(x) AS rc FROM (VALUES (1::INTEGER), (NULL::INTEGER), (2::INTEGER)) t(x)")
  expect_equal(calls_default_r, 2L)
  expect_equal(calls_default_rc, 2L)

  calls_special_r <- 0L
  calls_special_rc <- 0L
  invisible(rducks_register(con, "eval_null_special_r", function(x) { calls_special_r <<- calls_special_r + 1L; if (is.na(x)) 5L else x }, INTEGER, INTEGER, eval_mode = "R", null_handling = "special", side_effects = TRUE))
  invisible(rducks_register(con, "eval_null_special_rc", function(x) { calls_special_rc <<- calls_special_rc + 1L; if (is.na(x)) 5L else x }, INTEGER, INTEGER, eval_mode = "RC", null_handling = "special", side_effects = TRUE))
  expect_pair_equal("SELECT eval_null_special_r(x) AS r, eval_null_special_rc(x) AS rc FROM (VALUES (1::INTEGER), (NULL::INTEGER), (2::INTEGER)) t(x)")
  expect_equal(calls_special_r, 3L)
  expect_equal(calls_special_rc, 3L)

  invisible(rducks_register(con, "eval_error_null_r", function(x) if (x == 2L) stop("boom") else x, INTEGER, INTEGER, eval_mode = "R", exception_handling = "return_null", side_effects = TRUE))
  invisible(rducks_register(con, "eval_error_null_rc", function(x) if (x == 2L) stop("boom") else x, INTEGER, INTEGER, eval_mode = "RC", exception_handling = "return_null", side_effects = TRUE))
  expect_pair_equal("SELECT eval_error_null_r(i::INTEGER) AS r, eval_error_null_rc(i::INTEGER) AS rc FROM range(4) t(i)")

  invisible(rducks_register(con, "eval_rng_r", function(x) runif(1), INTEGER, DOUBLE, eval_mode = "R", side_effects = TRUE))
  invisible(rducks_register(con, "eval_rng_rc", function(x) runif(1), INTEGER, DOUBLE, eval_mode = "RC", side_effects = TRUE))
  set.seed(123)
  rng_r <- DBI::dbGetQuery(con, "SELECT eval_rng_r(i::INTEGER) AS x FROM range(1000) t(i)")$x
  set.seed(123)
  rng_rc <- DBI::dbGetQuery(con, "SELECT eval_rng_rc(i::INTEGER) AS x FROM range(1000) t(i)")$x
  expect_equal(rng_r, rng_rc)
  expect_equal(length(unique(rng_rc)), 1000L)
})
