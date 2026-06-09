library(Rducks)

local({
  con_r <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  con_c <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con_r, shutdown = TRUE), add = TRUE)
  on.exit(DBI::dbDisconnect(con_c, shutdown = TRUE), add = TRUE)
  rducks_enable(con_r, threads = "single")
  rducks_enable(con_c, threads = "single")
  rducks_set_execution_plan(con_c, rducks_execution_plan_internal("direct", "serial"))

  register_pair <- function(name, fun, args, returns, ..., side_effects = TRUE) {
    invisible(rducks_register_scalar_udf(con_r, name, fun, args, returns, ..., side_effects = side_effects))
    invisible(rducks_register_scalar_udf(con_c, name, fun, args, returns, ..., side_effects = side_effects))
  }

  expect_plan_equal <- function(sql) {
    out_r <- DBI::dbGetQuery(con_r, sql)
    out_c <- DBI::dbGetQuery(con_c, sql)
    expect_equal(out_r, out_c)
  }

  cases <- list(
    list("eval_i32", function(x) x + 1L, INTEGER, INTEGER,
         "SELECT eval_i32(i::INTEGER) AS x FROM range(20) t(i)"),
    list("eval_f64", function(x, y) x * 2 + y, c(DOUBLE, DOUBLE), DOUBLE,
         "SELECT eval_f64(i::DOUBLE, 0.5::DOUBLE) AS x FROM range(20) t(i)"),
    list("eval_noargs", function() 42L, character(), INTEGER,
         "SELECT eval_noargs() AS x"),
    list("eval_bool", function(x) !x, BOOLEAN, BOOLEAN,
         "SELECT eval_bool(x) AS x FROM (VALUES (TRUE), (FALSE)) t(x)"),
    list("eval_i8", function(x) as.integer(x + 1L), TINYINT, TINYINT,
         "SELECT eval_i8(x)::INTEGER AS x FROM (VALUES (41::TINYINT), (-2::TINYINT)) t(x)"),
    list("eval_u8", function(x) x + 1L, UTINYINT, UTINYINT,
         "SELECT eval_u8(x)::INTEGER AS x FROM (VALUES (41::UTINYINT), (2::UTINYINT)) t(x)"),
    list("eval_i16", function(x) as.integer(x + 1L), SMALLINT, SMALLINT,
         "SELECT eval_i16(x)::INTEGER AS x FROM (VALUES (41::SMALLINT), (-2::SMALLINT)) t(x)"),
    list("eval_u16", function(x) x + 1L, USMALLINT, USMALLINT,
         "SELECT eval_u16(x)::INTEGER AS x FROM (VALUES (41::USMALLINT), (2::USMALLINT)) t(x)"),
    list("eval_u32", function(x) x + 1, UINTEGER, UINTEGER,
         "SELECT eval_u32(x)::DOUBLE AS x FROM (VALUES (41::UINTEGER), (2::UINTEGER)) t(x)"),
    list("eval_f32", function(x) x + 1, FLOAT, FLOAT,
         "SELECT eval_f32(x)::DOUBLE AS x FROM (VALUES (1.25::FLOAT), (2.5::FLOAT)) t(x)"),
    list("eval_i64", function(x) x + rducks_bigint("1"), BIGINT, BIGINT,
         "SELECT eval_i64(x)::VARCHAR AS x FROM (VALUES (9223372036854775806::BIGINT), (-2::BIGINT)) t(x)"),
    list("eval_u64", function(x) x + rducks_ubigint("1"), UBIGINT, UBIGINT,
         "SELECT eval_u64(x)::VARCHAR AS x FROM (VALUES (18446744073709551614::UBIGINT), (2::UBIGINT)) t(x)"),
    list("eval_huge", function(x) x + rducks_hugeint("1"), HUGEINT, HUGEINT,
         "SELECT eval_huge(x)::VARCHAR AS x FROM (VALUES (170141183460469231731687303715884105726::HUGEINT), (-2::HUGEINT)) t(x)"),
    list("eval_uhuge", function(x) x + rducks_uhugeint("1"), UHUGEINT, UHUGEINT,
         "SELECT eval_uhuge(x)::VARCHAR AS x FROM (VALUES (340282366920938463463374607431768211454::UHUGEINT), (2::UHUGEINT)) t(x)"),
    list("eval_uuid", function(x) x, UUID, UUID,
         "SELECT eval_uuid(x)::VARCHAR AS x FROM (VALUES ('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::UUID), ('00000000-0000-0000-0000-000000000001'::UUID)) t(x)"),
    list("eval_interval", function(x) x + rducks_interval(1L, 2L, "3"), INTERVAL, INTERVAL,
         "SELECT eval_interval(x)::VARCHAR AS x FROM (VALUES (INTERVAL '1 month 1 day 1 microsecond'), (INTERVAL '2 days')) t(x)"),
    list("eval_bit", function(x) !x, BIT, BIT,
         "SELECT eval_bit(x)::VARCHAR AS x FROM (VALUES ('1010'::BIT), ('1111'::BIT)) t(x)"),
    list("eval_varchar", function(x) paste0(x, ":", nchar(x)), VARCHAR, VARCHAR,
         "SELECT eval_varchar(x) AS x FROM (VALUES ('a'), ('duck'), ('R')) t(x)"),
    list("eval_blob", function(x) c(x, as.raw(0xff)), BLOB, BLOB,
         "SELECT hex(eval_blob(x)) AS x FROM (VALUES (from_hex('00AA')), (from_hex('10'))) t(x)"),
    list("eval_date", function(x) x + 1, DATE, DATE,
         "SELECT eval_date(x)::VARCHAR AS x FROM (VALUES (DATE '2020-01-02'), (DATE '1970-01-01')) t(x)"),
    list("eval_time", function(x) x + 1, TIME, TIME,
         "SELECT eval_time(x)::VARCHAR AS x FROM (VALUES (TIME '01:02:03'), (TIME '23:59:58')) t(x)"),
    list("eval_timestamp", function(x) x + 1, TIMESTAMP, TIMESTAMP,
         "SELECT eval_timestamp(x)::VARCHAR AS x FROM (VALUES (TIMESTAMP '2020-01-02 03:04:05'), (TIMESTAMP '1970-01-01 00:00:00')) t(x)"),
    list("eval_decimal", function(x) x + rducks_decimal("1.25", 10, 2), DECIMAL(10, 2), DECIMAL(10, 2),
         "SELECT eval_decimal(x)::VARCHAR AS x FROM (VALUES (1.25::DECIMAL(10,2)), (2.50::DECIMAL(10,2))) t(x)"),
    list("eval_list", function(x) sum(x), INTEGER[], INTEGER,
         "SELECT eval_list(x) AS x FROM (VALUES ([1,2,3]::INTEGER[]), ([4,5]::INTEGER[])) t(x)"),
    list("eval_array", function(x) sum(x), INTEGER[3], INTEGER,
         "SELECT eval_array(x) AS x FROM (VALUES ([1,2,3]::INTEGER[3]), ([4,5,6]::INTEGER[3])) t(x)"),
    list("eval_make_list", function(x) c(x, x + 1L), INTEGER, INTEGER[],
         "SELECT list_sum(eval_make_list(i::INTEGER)) AS x FROM range(3) t(i)"),
    list("eval_struct", function(x) x$a + x$b, STRUCT(a = INTEGER, b = INTEGER), INTEGER,
         "SELECT eval_struct(x) AS x FROM (VALUES ({'a': 20, 'b': 22}::STRUCT(a INTEGER, b INTEGER)), ({'a': 1, 'b': 2}::STRUCT(a INTEGER, b INTEGER))) t(x)"),
    list("eval_make_struct", function(x) list(a = x, b = x + 1L), INTEGER, STRUCT(a = INTEGER, b = INTEGER),
         "SELECT (eval_make_struct(i::INTEGER)).b AS x FROM range(3) t(i)"),
    list("eval_nested", function(x) length(x$s) + as.integer(is.integer(x$s)), STRUCT(s = INTEGER[]), INTEGER,
         "SELECT eval_nested(x) AS x FROM (VALUES ({'s': [1,2,3]}::STRUCT(s INTEGER[])), ({'s': [4,5]}::STRUCT(s INTEGER[]))) t(x)"),
    list("eval_map", function(x) sum(x$values), MAP(VARCHAR, INTEGER), INTEGER,
         "SELECT eval_map(x) AS x FROM (VALUES (map(['a','b'], [20,22])), (map(['a','b'], [1,2]))) t(x)"),
    list("eval_make_map", function(x) list(keys = c('a', 'b'), values = c(x, x + 1L)), INTEGER, MAP(VARCHAR, INTEGER),
         "SELECT list_sum(map_values(eval_make_map(i::INTEGER))) AS x FROM range(3) t(i)"),
    list("eval_enum", function(x) x, ENUM(c("red", "blue")), ENUM(c("red", "blue")),
         "SELECT eval_enum(x)::VARCHAR AS x FROM (VALUES ('red'::ENUM('red','blue')), ('blue'::ENUM('red','blue'))) t(x)"),
    list("eval_union", function(x) if (identical(x$tag, "code")) rducks_union("label", paste0("c", x$value)) else rducks_union("code", 1L),
         UNION(code = INTEGER, label = VARCHAR), UNION(code = INTEGER, label = VARCHAR),
         "SELECT union_extract(eval_union(x), 'label') AS x FROM (SELECT union_value(code := 42)::UNION(code INTEGER, label VARCHAR) AS x)")
  )

  for (case in cases) {
    arrow_c_direct_supported <- all(vapply(
      c(Rducks:::rducks_as_type_list(case[[3L]]), list(Rducks:::rducks_as_type(case[[4L]]))),
      Rducks:::rducks_arrow_c_direct_mapping_supported,
      logical(1)
    ))
    if (arrow_c_direct_supported) {
      register_pair(case[[1L]], case[[2L]], case[[3L]], case[[4L]])
      expect_plan_equal(case[[5L]])
    } else {
      invisible(rducks_register_scalar_udf(con_r, case[[1L]], case[[2L]], case[[3L]], case[[4L]], side_effects = TRUE))
      expect_error(
        rducks_register_scalar_udf(con_c, case[[1L]], case[[2L]], case[[3L]], case[[4L]], side_effects = TRUE),
        "arrow_c direct marshalling is not implemented"
      )
      expect_true(NROW(DBI::dbGetQuery(con_r, case[[5L]])) >= 1L)
    }
  }

  calls_default_r <- 0L
  calls_default_c <- 0L
  invisible(rducks_register_scalar_udf(con_r, "eval_null_default", function(x) { calls_default_r <<- calls_default_r + 1L; x }, INTEGER, INTEGER, side_effects = TRUE))
  invisible(rducks_register_scalar_udf(con_c, "eval_null_default", function(x) { calls_default_c <<- calls_default_c + 1L; x }, INTEGER, INTEGER, side_effects = TRUE))
  expect_plan_equal("SELECT eval_null_default(x) AS x FROM (VALUES (1::INTEGER), (NULL::INTEGER), (2::INTEGER)) t(x)")
  expect_equal(calls_default_r, 2L)
  expect_equal(calls_default_c, 2L)

  calls_special_r <- 0L
  calls_special_c <- 0L
  invisible(rducks_register_scalar_udf(con_r, "eval_null_special", function(x) { calls_special_r <<- calls_special_r + 1L; if (is.na(x)) 5L else x }, INTEGER, INTEGER, null_handling = "special", side_effects = TRUE))
  invisible(rducks_register_scalar_udf(con_c, "eval_null_special", function(x) { calls_special_c <<- calls_special_c + 1L; if (is.na(x)) 5L else x }, INTEGER, INTEGER, null_handling = "special", side_effects = TRUE))
  expect_plan_equal("SELECT eval_null_special(x) AS x FROM (VALUES (1::INTEGER), (NULL::INTEGER), (2::INTEGER)) t(x)")
  expect_equal(calls_special_r, 3L)
  expect_equal(calls_special_c, 3L)

  register_pair("eval_null_special_bigint", function(x) as.integer(is.null(x)), BIGINT, INTEGER, null_handling = "special")
  expect_plan_equal("SELECT eval_null_special_bigint(NULL::BIGINT) AS x")

  register_pair("eval_null_special_blob", function(x) as.integer(is.null(x)), BLOB, INTEGER, null_handling = "special")
  expect_plan_equal("SELECT eval_null_special_blob(NULL::BLOB) AS x")

  register_pair("eval_error_null", function(x) if (x == 2L) stop("boom") else x, INTEGER, INTEGER,
                exception_handling = "return_null", side_effects = TRUE)
  expect_plan_equal("SELECT eval_error_null(i::INTEGER) AS x FROM range(4) t(i)")

  register_pair("eval_error_rethrow", function(x) if (x == 2L) stop("boom") else x, INTEGER, INTEGER,
                side_effects = TRUE)
  expect_error(DBI::dbGetQuery(con_r, "SELECT eval_error_rethrow(i::INTEGER) AS x FROM range(4) t(i)"), "Rducks")
  expect_error(DBI::dbGetQuery(con_c, "SELECT eval_error_rethrow(i::INTEGER) AS x FROM range(4) t(i)"), "Rducks")

  register_pair("eval_bad_return", function(x) c(x, x), INTEGER, INTEGER,
                exception_handling = "return_null", side_effects = TRUE)
  expect_error(DBI::dbGetQuery(con_r, "SELECT eval_bad_return(1::INTEGER) AS x"), "Rducks")
  expect_error(DBI::dbGetQuery(con_c, "SELECT eval_bad_return(1::INTEGER) AS x"), "Rducks")

  register_pair("eval_rng", function(x) runif(1), INTEGER, DOUBLE, side_effects = TRUE)
  set.seed(123)
  rng_r <- DBI::dbGetQuery(con_r, "SELECT eval_rng(i::INTEGER) AS x FROM range(1000) t(i)")$x
  set.seed(123)
  rng_c <- DBI::dbGetQuery(con_c, "SELECT eval_rng(i::INTEGER) AS x FROM range(1000) t(i)")$x
  expect_equal(rng_r, rng_c)
  expect_equal(length(unique(rng_c)), 1000L)
})
