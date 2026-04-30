library(Rducks)

expect_equal(rducks_type_normalize("integer"), "i32")
expect_equal(rducks_type_normalize(INTEGER), "i32")
expect_equal(rducks_type_normalize(INTEGER[]), "list<i32>")
expect_equal(rducks_type_normalize(INTEGER[3]), "i32[3]")
expect_equal(rducks_type_normalize(STRUCT(a = INTEGER, b = VARCHAR)), "struct<a:i32;b:varchar>")
expect_equal(rducks_type_normalize(MAP(VARCHAR, INTEGER)), "map<varchar;i32>")
expect_equal(
  rducks_duckdb_types(c("i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64", "f32", "f64", "varchar", "blob", "date", "time", "timestamp")),
  c("TINYINT", "UTINYINT", "SMALLINT", "USMALLINT", "INTEGER", "UINTEGER", "BIGINT", "UBIGINT", "FLOAT", "DOUBLE", "VARCHAR", "BLOB", "DATE", "TIME", "TIMESTAMP")
)
expect_equal(rducks_duckdb_signature("f", c("i32", "f64"), "bool"), "f(INTEGER, DOUBLE) -> BOOLEAN")
expect_true("rducks_argument_type_mapping" %in% getNamespaceExports("Rducks"))
expect_true(rducks_is_type(INTEGER))
expect_true(rducks_is_type(INTEGER[]))
expect_true(rducks_is_type(INTEGER[3]))
expect_true(rducks_is_type(STRUCT(a = INTEGER[], b = MAP(VARCHAR, INTEGER))))
expect_inherits(INTEGER, "rducks_scalar_type")
expect_inherits(INTEGER[], "rducks_list_type")
expect_inherits(INTEGER[3], "rducks_array_type")
expect_inherits(STRUCT(a = INTEGER), "rducks_struct_type")
expect_inherits(MAP(VARCHAR, INTEGER), "rducks_map_type")
expect_inherits(DECIMAL(10, 2), "rducks_decimal_type")
expect_inherits(ENUM(c("red", "blue")), "rducks_enum_type")
expect_inherits(UNION(i = INTEGER, s = VARCHAR), "rducks_union_type")
expect_true(rducks_is_type(STRUCT(x = LIST(UNION(i = INTEGER, e = ENUM(c("red", "blue")))), y = MAP(VARCHAR, DECIMAL(10, 2)))))
expect_identical(rducks_check_return(ENUM(c("red", "blue")), rducks_enum("red", c("red", "blue"))), rducks_enum("red", c("red", "blue")))
expect_identical(rducks_check_return(UNION(i = INTEGER, s = VARCHAR), rducks_union("i", 1L)), rducks_union("i", 1L))
expect_error(rducks_check_return(ENUM(c("red", "blue")), "green"), "enum values")
expect_error(rducks_check_return(UNION(i = INTEGER), rducks_union("s", "x")), "union tag")
expect_equal(rducks_type_kind(UNION(i = INTEGER, s = VARCHAR)), "union")
expect_equal(rducks_type_sql(DECIMAL(10, 2)), "DECIMAL(10, 2)")
expect_equal(rducks_type_parameters(ENUM(c("red", "blue")))$levels, c("red", "blue"))
expect_equal(rducks_type_child_names(STRUCT(a = INTEGER, b = VARCHAR)), c("a", "b"))
expect_equal(vapply(rducks_type_children(MAP(VARCHAR, INTEGER)), rducks_type_sql, character(1)), c("VARCHAR", "INTEGER"))
expect_equal(as.character(UNION(i = INTEGER, s = VARCHAR)), "UNION(i INTEGER, s VARCHAR)")
expect_equal(length(UNION(i = INTEGER, s = VARCHAR)), 1L)
printed_type <- capture.output(print(UNION(i = INTEGER, s = VARCHAR)))
expect_true(any(grepl("children", printed_type, fixed = TRUE)))
printed_type_list <- capture.output(print(c(INTEGER, DOUBLE)))
expect_true(any(grepl("rducks_type_list", printed_type_list, fixed = TRUE)))
expect_equal(rducks_argument_type_mapping(UUID)$argument_kind, "exotic")
expect_equal(rducks_argument_type_mapping(STRUCT(x = DECIMAL(10, 2)))$argument_kind, "struct")
bad_type <- INTEGER
attr(bad_type, "kind") <- "wat"
expect_false(rducks_is_type(bad_type))

scalar_mapping <- rducks_argument_type_mapping()
expect_equal(
  scalar_mapping$rducks_type,
  c("bool", "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64", "f32", "f64", "varchar", "blob", "date", "time", "timestamp", "hugeint", "uhugeint", "uuid", "interval", "bit")
)
expect_equal(scalar_mapping$r_type[scalar_mapping$rducks_type == "i64"], "rducks_bigint")
expect_equal(scalar_mapping$r_type[scalar_mapping$rducks_type == "u64"], "rducks_ubigint")
expect_equal(rducks_duckdb_types(scalar_mapping$rducks_type), scalar_mapping$duckdb_sql)
expect_true(all(c(
  "rducks_type", "duckdb_sql", "argument_kind", "r_type",
  "r_value_passed_to_fun", "sql_null_in_callback", "copy_semantics",
  "uses_r_double_for_integer", "uses_r_double_for_float", "precision_may_be_lost",
  "notes"
) %in% names(scalar_mapping)))

composite_types <- list(LIST(INTEGER), INTEGER[], BIGINT[3], STRUCT(a = INTEGER, b = VARCHAR), MAP(VARCHAR, INTEGER))
composite_mapping <- rducks_argument_type_mapping(composite_types)
expect_equal(
  composite_mapping$duckdb_sql,
  c("INTEGER[]", "INTEGER[]", "BIGINT[3]", "STRUCT(a INTEGER, b VARCHAR)", "MAP(VARCHAR, INTEGER)")
)
expect_equal(composite_mapping$argument_kind, c("list", "list", "array", "struct", "map"))
expect_equal(composite_mapping$r_value_passed_to_fun[[1L]], "integer vector")
expect_equal(composite_mapping$r_value_passed_to_fun[[3L]], "rducks_bigint vector of length 3")
expect_false(composite_mapping$precision_may_be_lost[[3L]])

for (type in c(as.list(scalar_mapping$rducks_type), composite_types)) {
  token <- rducks_type_normalize(type)
  symbol <- paste0("rducks_mapping_codegen_", gsub("[^A-Za-z0-9]", "_", token))
  spec <- rducks_udf_spec(symbol, function(x) 1L, type, INTEGER)
  expect_equal(spec$argument_type_mapping$rducks_type, token)
  src <- rducks_generate_scalar_wrapper(spec)
  expect_true(is.character(src) && length(src) == 1L && grepl("R_tryEvalSilent", src, fixed = TRUE))
  expect_true(grepl("#define _Complex", src, fixed = TRUE))
}
expect_equal(rducks_udf_spec("row_mode", function(x) x, INTEGER, INTEGER, mode = "row")$mode, "row")
expect_error(rducks_udf_spec("compiled_alias", function(x) x, INTEGER, INTEGER, mode = "compiled"), "arg")
expect_error(rducks_type_normalize("list<i32>"), "constructors")
expect_error(rducks_udf_spec("bad_mapping", function(x) x, LIST("nope"), INTEGER), "unsupported")
expect_identical(rducks_check_argument(INTEGER, 1L, name = "x"), 1L)
expect_identical(rducks_check_argument(BIGINT, rducks_bigint("1"), name = "x"), rducks_bigint("1"))
expect_identical(rducks_check_argument(INTEGER[], c(1L, NA_integer_), name = "x"), c(1L, NA_integer_))
expect_identical(rducks_check_return(INTEGER[3], c(1L, 2L, 3L)), c(1L, 2L, 3L))
expect_identical(rducks_check_return(STRUCT(a = INTEGER, b = VARCHAR), list(a = 1L, b = "x")), list(a = 1L, b = "x"))
expect_identical(rducks_check_return(MAP(VARCHAR, INTEGER), list(keys = c("a", "b"), values = c(1L, 2L))), list(keys = c("a", "b"), values = c(1L, 2L)))
expect_error(rducks_check_argument(INTEGER, "x", name = "x"), "INTEGER")
expect_error(rducks_check_return(INTEGER, NaN), "finite")
expect_error(rducks_check_return(INTEGER, Inf), "finite")
expect_error(rducks_check_return(INTEGER, 1.5), "whole")
expect_identical(rducks_check_return(DOUBLE, Inf), Inf)
expect_true(is.nan(rducks_check_return(DOUBLE, NaN)))
expect_error(rducks_check_return(INTEGER[3], c(1L, 2L)), "length 3")
expect_error(rducks_check_return(STRUCT(a = INTEGER), list(b = 1L)), "field")

uuid <- rducks_uuid(c("A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11", NA))
expect_inherits(uuid, "rducks_uuid")
expect_equal(as.character(uuid)[[1L]], "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")
expect_error(rducks_uuid("not-a-uuid"), "canonical")

big <- rducks_bigint(c("-00123", "9223372036854775807"))
expect_inherits(big, "rducks_bigint")
expect_equal(as.character(big), c("-123", "9223372036854775807"))
expect_equal(as.character(rducks_bigint("9223372036854775806") + rducks_bigint("1")), "9223372036854775807")
expect_error(rducks_bigint("9223372036854775807") + rducks_bigint("1"), "range")
expect_equal(as.character(rducks_ubigint("18446744073709551614") + rducks_ubigint("1")), "18446744073709551615")
expect_error(rducks_bigint(9007199254740993), "character")
expect_error(rducks_hugeint(9007199254740993), "character")
expect_error(rducks_ubigint("18446744073709551616"), "range")
expect_equal(rducks_value_type(big[1]), "BIGINT")
expect_equal(rducks_duckdb_literal(big[1]), "'-123'::BIGINT")

huge <- rducks_hugeint(c("-00123", "170141183460469231731687303715884105727"))
expect_inherits(huge, "rducks_hugeint")
expect_equal(as.character(huge), c("-123", "170141183460469231731687303715884105727"))
expect_equal(as.character(rducks_uhugeint("000123")), "123")
expect_error(rducks_uhugeint("-1"), "unsigned")
expect_error(rducks_hugeint(2^60), "character")
expect_error(rducks_hugeint("170141183460469231731687303715884105728"), "range")
expect_error(rducks_uhugeint("340282366920938463463374607431768211456"), "range")
expect_equal(as.character(rducks_hugeint("999999999999999999999999") + rducks_hugeint("1")), "1000000000000000000000000")
expect_equal(as.character(rducks_hugeint("10") - rducks_hugeint("25")), "-15")
expect_equal(as.character(-rducks_hugeint("10")), "-10")
expect_equal(as.character(rducks_uhugeint("10") + rducks_uhugeint("25")), "35")
expect_error(rducks_uhugeint("10") - rducks_uhugeint("25"), "negative")
expect_equal(as.character(c(rducks_hugeint("1"), rducks_hugeint("2"))), c("1", "2"))
expect_true(is.numeric(suppressWarnings(as.numeric(rducks_hugeint("100000000000000000000")))))

dec <- rducks_decimal(c("1.2", "-0.01"), width = 10, scale = 2)
expect_inherits(dec, "rducks_decimal")
expect_equal(as.character(dec), c("1.20", "-0.01"))
expect_equal(as.character(dec[1]), "1.20")
expect_equal(as.character(rducks_decimal("1.20", 5, 2) + rducks_decimal("2.05", 5, 2)), "3.25")
expect_equal(as.character(rducks_decimal("1.20", 5, 2) - rducks_decimal("2.05", 5, 2)), "-0.85")
expect_equal(as.character(-rducks_decimal("1.20", 5, 2)), "-1.20")
expect_equal(as.character(c(rducks_decimal("1.20", 5, 2), rducks_decimal("2", 5, 2))), c("1.20", "2.00"))
expect_true(is.numeric(suppressWarnings(as.numeric(rducks_decimal("1.20", 5, 2)))))
expect_error(rducks_decimal("1.234", width = 5, scale = 2), "fractional")

interval <- rducks_interval(months = 1:2, days = 0L, micros = c("3", "4"))
expect_inherits(interval, "rducks_interval")
expect_equal(length(interval), 2L)
expect_equal(as.data.frame(interval)$micros, c("3", "4"))
expect_equal(as.data.frame(interval[1])$months, 1L)
expect_equal(as.data.frame(rducks_interval(1L, 2L, "3") + rducks_interval(2L, 3L, "4"))$micros, "7")
expect_equal(as.data.frame(rducks_interval(1L, 2L, "3") - rducks_interval(2L, 3L, "4"))$months, -1L)
expect_equal(as.character(c(rducks_interval(1L, 2L, "3"), rducks_interval(4L, 5L, "6"))), c("1 months 2 days 3 micros", "4 months 5 days 6 micros"))
expect_equal(rducks_as_date(as.POSIXct("2020-01-02 03:04:05", tz = "UTC")), as.Date("2020-01-02"))
expect_equal(rducks_as_time(as.POSIXct("2020-01-02 03:04:05", tz = "UTC")), 11045)
expect_equal(rducks_as_time("03:04:05.5"), 11045.5)
expect_equal(as.numeric(rducks_as_timestamp(as.Date("2020-01-02"), tz = "UTC")), as.numeric(as.POSIXct("2020-01-02", tz = "UTC")))
expect_equal(as.data.frame(rducks_as_interval(as.difftime(1.5, units = "secs")))$micros, "1500000")
expect_equal(as.data.frame(rducks_as_interval(rducks_interval(1L, 2L, "3"), months = 1L, days = 1L))$months, 2L)
expect_equal(as.data.frame(rducks_interval_between(as.POSIXct("2020-01-02 00:00:00", tz = "UTC"), as.POSIXct("2020-01-02 00:00:01", tz = "UTC")))$micros, "1000000")
expect_error(rducks_as_date(Inf), "finite")
expect_error(rducks_as_timestamp(Inf), "finite")
expect_error(rducks_as_time(Inf), "86400")
expect_error(rducks_as_time("23:59:60"), "within one day")
expect_error(rducks_as_time(86400), "86400")
expect_error(rducks_as_time(86399.9999996), "rounding")
expect_error(rducks_interval(0L, 0L, "9223372036854775808"), "range")

bits <- rducks_bits("10110001")
expect_inherits(bits, "rducks_bits")
expect_equal(as.character(bits), "10110001")
expect_equal(as.integer(bits), c(1L, 0L, 1L, 1L, 0L, 0L, 0L, 1L))
expect_equal(as.logical(rducks_bits("10")), c(TRUE, FALSE))
expect_equal(rducks_bits_raw(bits), as.raw(0xb1))
expect_equal(as.character(rducks_bits(as.raw(0xb1), length = 8L)), "10110001")
expect_equal(as.character(c(rducks_bits("101"), rducks_bits("00"))), "10100")
expect_error(rducks_bits(""), "at least one bit")
expect_error(rducks_bits("102"), "0 and 1")

enum <- rducks_enum(c("low", "high"), levels = c("low", "medium", "high"))
expect_inherits(enum, "rducks_enum")
expect_equal(levels(enum), c("low", "medium", "high"))
expect_equal(as.character(c(enum[1], enum[2])), c("low", "high"))
expect_error(rducks_enum("bad", levels = c("good")), "levels")

union <- rducks_union("s", "duck")
expect_inherits(union, "rducks_union")
expect_equal(union$tag, "s")
expect_equal(union$value, "duck")
expect_inherits(c(union, rducks_union("i", 1L)), "rducks_union_list")
expect_error(rducks_union("", 1), "tag")

expect_equal(rducks_value_type(uuid[1]), "UUID")
expect_equal(rducks_duckdb_literal(uuid[1]), "'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::UUID")
expect_true(rducks_hugeint("10") > rducks_hugeint("2"))
expect_true(rducks_hugeint("-10") < rducks_hugeint("2"))
expect_true(rducks_uhugeint("10") >= rducks_uhugeint("10"))
expect_true(rducks_decimal("1.20", width = 5, scale = 2) == rducks_decimal("1.2", width = 5, scale = 2))
expect_equal(rducks_value_type(dec), "DECIMAL(10, 2)")
expect_equal(rducks_duckdb_literal(dec[1]), "'1.20'::DECIMAL(10, 2)")
expect_equal(rducks_value_type(interval), "INTERVAL")
expect_equal(
  rducks_duckdb_literal(rducks_interval(months = 1L, days = 2L, micros = "3")),
  "((INTERVAL '1 month' * 1) + (INTERVAL '1 day' * 2) + (INTERVAL '1 microsecond' * 3))"
)
expect_equal(length(bits), 8L)
expect_equal(as.character(bits[1:4]), "1011")
expect_equal(as.character(bits & rducks_bits("11110000")), "10110000")
expect_equal(as.character(bits | rducks_bits("00001111")), "10111111")
expect_equal(as.character(rducks_bits_xor(bits, rducks_bits("11111111"))), "01001110")
expect_equal(as.character(!rducks_bits("1010")), "0101")
expect_equal(rducks_value_type(enum), "ENUM('low', 'medium', 'high')")
expect_equal(rducks_duckdb_literal(enum[1]), "'low'::ENUM('low', 'medium', 'high')")
expect_error(rducks_duckdb_literal(union), "UNION literals")

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

  reg1 <- rducks_register(con, "rducks_plus_one", function(x) x + 1, DOUBLE, DOUBLE)
  expect_inherits(reg1, "rducks_registration")
  expect_equal(reg1$spec$mode, "row")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_plus_one(41.0) AS x")$x, 42)

  reg_soft <- rducks_register(con, "rducks_soft_unregister", function(x) x + 1L, INTEGER, INTEGER)
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_soft_unregister(1::INTEGER) AS x")$x, 2L)
  expect_null(rducks_unregister(reg_soft))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_soft_unregister(1::INTEGER) AS x"), "unregistered")
  invisible(rducks_register(con, "rducks_soft_unregister", function(x) x + 2L, INTEGER, INTEGER))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_soft_unregister(1::INTEGER) AS x")$x, 3L)

  expect_error(
    rducks_register(con, "rducks_arrow_lapply", function(x) x, INTEGER, INTEGER, mode = "arrow_lapply"),
    "reserved"
  )

  reg2 <- rducks_register(con, "rducks_add", function(x, y) x + y, c(DOUBLE, DOUBLE), DOUBLE)
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_add(1.5, 2.25) AS x")$x, 3.75)

  reg3 <- rducks_register(con, "rducks_i32_double", function(x) as.integer(x * 2L), "i32", "i32")
  expect_inherits(reg3$compiled, "rducks_compiled_wrapper")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_i32_double(21::INTEGER) AS x")$x, 42L)

  reg4 <- rducks_register(con, "rducks_not", function(x) !x, "bool", "bool")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_not(TRUE) AS x")$x, FALSE)

  reg5 <- rducks_register(con, "rducks_greet", function(x) paste0('hi ', x), "varchar", "varchar")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_greet('duck') AS x")$x, "hi duck")

  invisible(rducks_register(con, "rducks_i8", function(x) as.integer(x + 1L), "i8", "i8"))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_i8(41::TINYINT) AS x")$x, 42L)

  invisible(rducks_register(con, "rducks_u8", function(x) x + 1L, "u8", "u8"))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_u8(41::UTINYINT) AS x")$x, 42L)

  invisible(rducks_register(con, "rducks_i16", function(x) as.integer(x + 1L), "i16", "i16"))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_i16(41::SMALLINT) AS x")$x, 42L)

  invisible(rducks_register(con, "rducks_u16", function(x) x + 1L, "u16", "u16"))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_u16(41::USMALLINT) AS x")$x, 42L)

  expect_warning(
    invisible(rducks_register(con, "rducks_u32", function(x) x + 1, "u32", "u32")),
    "R numeric"
  )
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
  invisible(rducks_register(con, "rducks_decimal_null", function() rducks_decimal(NA_character_, 10, 2), character(), DECIMAL(10, 2)))
  expect_true(is.na(DBI::dbGetQuery(con, "SELECT rducks_decimal_null() AS x")$x))
  invisible(rducks_register(con, "rducks_decimal_list_null", function() list(rducks_decimal("1.23", 10, 2), rducks_decimal(NA_character_, 10, 2)), character(), LIST(DECIMAL(10, 2))))
  expect_equal(DBI::dbGetQuery(con, "SELECT list_sum(rducks_decimal_list_null()) AS x")$x, 1.23)

  invisible(rducks_register(con, "rducks_enum_echo", function(x) x, ENUM(c("red", "blue")), ENUM(c("red", "blue"))))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_enum_echo('red'::ENUM('red','blue'))::VARCHAR AS x")$x, "red")

  invisible(rducks_register(con, "rducks_bit_not", function(x) !x, BIT, BIT))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_bit_not('1010'::BIT)::VARCHAR AS x")$x, "0101")

  invisible(rducks_register(con, "rducks_union_flip", function(x) if (identical(x$tag, "code")) rducks_union("label", paste0("c", x$value)) else rducks_union("code", 1L), UNION(code = INTEGER, label = VARCHAR), UNION(code = INTEGER, label = VARCHAR)))
  expect_equal(as.character(DBI::dbGetQuery(con, "SELECT union_tag(rducks_union_flip(union_value(code := 42)::UNION(code INTEGER, label VARCHAR))) AS x")$x), "label")
  expect_equal(DBI::dbGetQuery(con, "SELECT union_extract(rducks_union_flip(union_value(code := 42)::UNION(code INTEGER, label VARCHAR)), 'label') AS x")$x, "c42")

  invisible(rducks_register(con, "rducks_blob", function(x) c(x, as.raw(0xff)), "blob", "blob"))
  expect_equal(DBI::dbGetQuery(con, "SELECT hex(rducks_blob(from_hex('00AA'))) AS x")$x, "00AAFF")

  invisible(rducks_register(con, "rducks_date", function(x) x + 1, "date", "date"))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_date(DATE '2020-01-02') AS x")$x, as.Date("2020-01-03"))

  invisible(rducks_register(con, "rducks_time", function(x) x + 1, "time", "time"))
  expect_equal(DBI::dbGetQuery(con, "SELECT CAST(rducks_time(TIME '01:02:03') AS VARCHAR) AS x")$x, "01:02:04")
  invisible(rducks_register(con, "rducks_time_fraction", function() rducks_as_time("00:00:00.1234567"), character(), TIME))
  expect_equal(DBI::dbGetQuery(con, "SELECT CAST(rducks_time_fraction() AS VARCHAR) AS x")$x, "00:00:00.123457")
  invisible(rducks_register(con, "rducks_time_bad", function() -1, character(), TIME))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_time_bad() AS x"), "Rducks")
  invisible(rducks_register(con, "rducks_time_round_bad", function() 86399.9999996, character(), TIME))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_time_round_bad() AS x"), "Rducks")
  invisible(rducks_register(con, "rducks_time_struct_fraction", function() list(t = rducks_as_time("00:00:00.1234567")), character(), STRUCT(t = TIME)))
  expect_equal(DBI::dbGetQuery(con, "SELECT CAST((rducks_time_struct_fraction()).t AS VARCHAR) AS x")$x, "00:00:00.123457")
  invisible(rducks_register(con, "rducks_time_struct_bad", function() list(t = 86400), character(), STRUCT(t = TIME)))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_time_struct_bad() AS x"), "marshal")

  invisible(rducks_register(con, "rducks_timestamp", function(x) x + 1, "timestamp", "timestamp"))
  expect_equal(DBI::dbGetQuery(con, "SELECT CAST(rducks_timestamp(TIMESTAMP '2020-01-02 03:04:05') AS VARCHAR) AS x")$x, "2020-01-02 03:04:06")
  invisible(rducks_register(con, "rducks_timestamp_fraction", function() as.POSIXct("1970-01-01", tz = "UTC") + 0.1234567, character(), TIMESTAMP))
  expect_equal(DBI::dbGetQuery(con, "SELECT epoch_us(rducks_timestamp_fraction()) AS x")$x, 123457)
  invisible(rducks_register(con, "rducks_timestamp_bad", function() 1e20, character(), TIMESTAMP))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_timestamp_bad() AS x"), "Rducks")
  invisible(rducks_register(con, "rducks_timestamp_edge_bad", function() 9223372036854.775, character(), TIMESTAMP))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_timestamp_edge_bad() AS x"), "Rducks")

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

  invisible(rducks_register(con, "rducks_i32_na_return", function() NA_integer_, character(), INTEGER))
  expect_true(is.na(DBI::dbGetQuery(con, "SELECT rducks_i32_na_return() AS x")$x))
  invisible(rducks_register(con, "rducks_i32_nan_bad", function() NaN, character(), INTEGER))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_i32_nan_bad() AS x"), "Rducks")
  invisible(rducks_register(con, "rducks_i32_inf_bad", function() Inf, character(), INTEGER))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_i32_inf_bad() AS x"), "Rducks")
  invisible(rducks_register(con, "rducks_i32_fraction_bad", function() 1.5, character(), INTEGER))
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_i32_fraction_bad() AS x"), "Rducks")
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
