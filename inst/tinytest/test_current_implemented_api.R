library(Rducks)

expect_equal(rducks_type_normalize("integer"), "i32")
expect_equal(rducks_type_normalize(INTEGER), "i32")
expect_equal(rducks_type_normalize(INTEGER[]), "list<i32>")
expect_equal(rducks_type_normalize(INTEGER[3]), "i32[3]")
expect_equal(rducks_type_normalize(STRUCT(a = INTEGER, b = VARCHAR)), "struct<a:i32;b:varchar>")
expect_equal(rducks_type_normalize(MAP(VARCHAR, INTEGER)), "map<varchar;i32>")
expect_equal(rducks_types_normalize(c(INTEGER, DOUBLE)), c("i32", "f64"))
expect_equal(
  rducks_duckdb_types(c("i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64", "f32", "f64", "varchar", "blob", "date", "time", "timestamp")),
  c("TINYINT", "UTINYINT", "SMALLINT", "USMALLINT", "INTEGER", "UINTEGER", "BIGINT", "UBIGINT", "FLOAT", "DOUBLE", "VARCHAR", "BLOB", "DATE", "TIME", "TIMESTAMP")
)
expect_equal(rducks_duckdb_signature("f", c("i32", "f64"), "bool"), "f(INTEGER, DOUBLE) -> BOOLEAN")
expect_true("rducks_argument_type_mapping" %in% getNamespaceExports("Rducks"))

scalar_mapping <- rducks_argument_type_mapping()
expect_equal(
  scalar_mapping$rducks_type,
  c("bool", "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64", "f32", "f64", "varchar", "blob", "date", "time", "timestamp")
)
expect_equal(rducks_duckdb_types(scalar_mapping$rducks_type), scalar_mapping$duckdb_sql)
expect_true(all(c(
  "rducks_type", "duckdb_sql", "argument_kind", "r_type",
  "r_value_passed_to_fun", "sql_null_in_callback", "copy_semantics",
  "uses_r_double_for_integer", "uses_r_double_for_float", "precision_may_be_lost",
  "notes"
) %in% names(scalar_mapping)))

composite_mapping <- rducks_argument_type_mapping(c(LIST(INTEGER), INTEGER[], BIGINT[3], STRUCT(a = INTEGER, b = VARCHAR), MAP(VARCHAR, INTEGER)))
expect_equal(
  composite_mapping$duckdb_sql,
  c("INTEGER[]", "INTEGER[]", "BIGINT[3]", "STRUCT(a INTEGER, b VARCHAR)", "MAP(VARCHAR, INTEGER)")
)
expect_equal(composite_mapping$argument_kind, c("list", "list", "array", "struct", "map"))
expect_equal(composite_mapping$r_value_passed_to_fun[[1L]], "integer vector")
expect_equal(composite_mapping$r_value_passed_to_fun[[3L]], "numeric vector of length 3")
expect_true(composite_mapping$precision_may_be_lost[[3L]])

for (token in c(scalar_mapping$rducks_type, composite_mapping$rducks_type)) {
  symbol <- paste0("rducks_mapping_codegen_", gsub("[^A-Za-z0-9]", "_", token))
  spec <- rducks_udf_spec(symbol, function(x) 1L, token, "i32")
  expect_equal(spec$argument_type_mapping$rducks_type, rducks_type_normalize(token))
  src <- rducks_generate_scalar_wrapper(spec)
  expect_true(is.character(src) && length(src) == 1L && grepl("R_tryEvalSilent", src, fixed = TRUE))
  expect_true(grepl("#define _Complex", src, fixed = TRUE))
}
expect_equal(rducks_udf_spec("row_mode", function(x) x, INTEGER, INTEGER, mode = "row")$mode, "row")
expect_equal(rducks_udf_spec("compiled_alias", function(x) x, INTEGER, INTEGER, mode = "compiled")$mode, "row")
expect_error(rducks_udf_spec("bad_mapping", function(x) x, "list<nope>", "i32"), "unsupported")

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

  expect_warning(
    invisible(rducks_register(con, "rducks_u64", function(x) x + 1, "u64", "u64")),
    "2\\^53"
  )
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_u64(41::UBIGINT) AS x")$x, 42)

  invisible(rducks_register(con, "rducks_blob", function(x) c(x, as.raw(0xff)), "blob", "blob"))
  expect_equal(DBI::dbGetQuery(con, "SELECT hex(rducks_blob(from_hex('00AA'))) AS x")$x, "00AAFF")

  invisible(rducks_register(con, "rducks_date", function(x) x + 1, "date", "date"))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_date(DATE '2020-01-02') AS x")$x, as.Date("2020-01-03"))

  invisible(rducks_register(con, "rducks_time", function(x) x + 1, "time", "time"))
  expect_equal(DBI::dbGetQuery(con, "SELECT CAST(rducks_time(TIME '01:02:03') AS VARCHAR) AS x")$x, "01:02:04")

  invisible(rducks_register(con, "rducks_timestamp", function(x) x + 1, "timestamp", "timestamp"))
  expect_equal(DBI::dbGetQuery(con, "SELECT CAST(rducks_timestamp(TIMESTAMP '2020-01-02 03:04:05') AS VARCHAR) AS x")$x, "2020-01-02 03:04:06")

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

  many_args <- rep("f64", 20)
  invisible(rducks_register(con, "rducks_sum20", function(...) sum(unlist(list(...))), many_args, "f64"))
  sum20_sql <- paste(rep("1.0", 20), collapse = ", ")
  expect_equal(DBI::dbGetQuery(con, sprintf("SELECT rducks_sum20(%s) AS x", sum20_sql))$x, 20)

  invisible(rducks_register(con, "rducks_tmp", function(x) x + 10, "f64", "f64"))
  gc()
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_tmp(32.0) AS x")$x, 42)
}
