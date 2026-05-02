library(Rducks)

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  invisible(rducks_register(con, "rducks_i8", function(x) as.integer(x + 1L), "i8", "i8"))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_i8(41::TINYINT) AS x")$x, 42L)

  invisible(rducks_register(con, "rducks_u8", function(x) x + 1L, "u8", "u8"))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_u8(41::UTINYINT) AS x")$x, 42L)

  invisible(rducks_register(con, "rducks_i16", function(x) as.integer(x + 1L), "i16", "i16"))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_i16(41::SMALLINT) AS x")$x, 42L)

  invisible(rducks_register(con, "rducks_u16", function(x) x + 1L, "u16", "u16"))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_u16(41::USMALLINT) AS x")$x, 42L)

  invisible(rducks_register(con, "rducks_u32", function(x) x + 1, "u32", "u32"))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_u32(41::UINTEGER) AS x")$x, 42)

  invisible(rducks_register(con, "rducks_u64", function(x) x + rducks_ubigint("1"), "u64", "u64"))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_u64(18446744073709551614::UBIGINT)::VARCHAR AS x")$x, "18446744073709551615")

  invisible(rducks_register(con, "rducks_i64", function(x) x + rducks_bigint("1"), "i64", "i64"))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_i64(9223372036854775806::BIGINT)::VARCHAR AS x")$x, "9223372036854775807")

  invisible(rducks_register(con, "rducks_huge", function(x) x + rducks_hugeint("1"), HUGEINT, HUGEINT))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_huge(170141183460469231731687303715884105726::HUGEINT)::VARCHAR AS x")$x, "170141183460469231731687303715884105727")

  invisible(rducks_register(con, "rducks_uhuge", function(x) x + rducks_uhugeint("1"), UHUGEINT, UHUGEINT))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_uhuge(340282366920938463463374607431768211454::UHUGEINT)::VARCHAR AS x")$x, "340282366920938463463374607431768211455")

  invisible(rducks_register(con, "rducks_uuid_echo", function(x) x, UUID, UUID))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_uuid_echo('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::UUID)::VARCHAR AS x")$x, "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")

  invisible(rducks_register(con, "rducks_interval_add", function(x) x + rducks_interval(1L, 2L, "3"), INTERVAL, INTERVAL))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_interval_add(INTERVAL '1 month 1 day 1 microsecond')::VARCHAR AS x")$x, "2 months 3 days 00:00:00.000004")
  invisible(rducks_register(con, "rducks_interval_bad", function() list(months = "bad", days = 0L, micros = "1"), character(), INTERVAL))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_interval_bad() AS x"), "marshal")

  invisible(rducks_register(con, "rducks_decimal_add", function(x) x + rducks_decimal("1.25", 10, 2), DECIMAL(10, 2), DECIMAL(10, 2)))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_decimal_add(2.50::DECIMAL(10,2))::VARCHAR AS x")$x, "3.75")
  invisible(rducks_register(con, "rducks_decimal_small_add", function(x) x + rducks_decimal("1", 3, 0), DECIMAL(3, 0), DECIMAL(3, 0)))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_decimal_small_add(41::DECIMAL(3,0))::VARCHAR AS x")$x, "42")
  invisible(rducks_register(con, "rducks_decimal_too_precise", function() rducks_decimal("1.234", 5, 3), character(), DECIMAL(10, 2)))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_decimal_too_precise() AS x"), "fractional")
  invisible(rducks_register(con, "rducks_decimal_plain_numeric_bad", function() 1.23, character(), DECIMAL(10, 2)))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_decimal_plain_numeric_bad() AS x"), "rducks_decimal")
  invisible(rducks_register(con, "rducks_decimal_length_bad", function() c(rducks_decimal("1.00", 10, 2), rducks_decimal("2.00", 10, 2)), character(), DECIMAL(10, 2)))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_decimal_length_bad() AS x"), "length 1")
  invisible(rducks_register(con, "rducks_decimal_null", function() rducks_decimal(NA_character_, 10, 2), character(), DECIMAL(10, 2)))
  expect_true(is.na(DBI::dbGetQuery(con, "SELECT rducks_decimal_null() AS x")$x))
  invisible(rducks_register(con, "rducks_decimal_list_null", function() list(rducks_decimal("1.23", 10, 2), rducks_decimal(NA_character_, 10, 2)), character(), LIST(DECIMAL(10, 2))))
  expect_equal(DBI::dbGetQuery(con, "SELECT list_sum(rducks_decimal_list_null()) AS x")$x, 1.23)
})
