library(Rducks)

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  invisible(rducks_register_scalar_udf(con, "rducks_enum_echo", function(x) x, ENUM(c("red", "blue")), ENUM(c("red", "blue"))))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_enum_echo('red'::ENUM('red','blue'))::VARCHAR AS x")$x, "red")

  invisible(rducks_register_scalar_udf(con, "rducks_bit_not", function(x) !x, BIT, BIT))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_bit_not('1010'::BIT)::VARCHAR AS x")$x, "0101")

  invisible(rducks_register_scalar_udf(con, "rducks_union_flip", function(x) if (identical(x$tag, "code")) rducks_union("label", paste0("c", x$value)) else rducks_union("code", 1L), UNION(code = INTEGER, label = VARCHAR), UNION(code = INTEGER, label = VARCHAR)))
  expect_equal(as.character(DBI::dbGetQuery(con, "SELECT union_tag(rducks_union_flip(union_value(code := 42)::UNION(code INTEGER, label VARCHAR))) AS x")$x), "label")
  expect_equal(DBI::dbGetQuery(con, "SELECT union_extract(rducks_union_flip(union_value(code := 42)::UNION(code INTEGER, label VARCHAR)), 'label') AS x")$x, "c42")

  invisible(rducks_register_scalar_udf(con, "rducks_blob", function(x) c(x, as.raw(0xff)), "blob", "blob"))
  expect_equal(DBI::dbGetQuery(con, "SELECT hex(rducks_blob(from_hex('00AA'))) AS x")$x, "00AAFF")

  rducks_set_execution_plan(con, rducks_execution_plan("arrow_c", "serial"))
  invisible(rducks_register_scalar_udf(con, "rducks_enum_arrow_c", function(x) x, ENUM(c("red", "blue")), ENUM(c("red", "blue"))))
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_enum_arrow_c('blue'::ENUM('red','blue'))::VARCHAR AS x")$x, "blue")
  enum_explain <- rducks_explain_udf(con, "rducks_enum_arrow_c")
  expect_equal(enum_explain$evaluator, "RC")
  expect_true(enum_explain$arrow_c_chunks >= 1)
  expect_equal(enum_explain$arrow_r_chunks, 0)

  invisible(rducks_register_scalar_udf(con, "rducks_union_arrow_c", function(x) {
    if (identical(x$tag, "code")) rducks_union("label", paste0("c", x$value)) else rducks_union("code", 1L)
  }, UNION(code = INTEGER, label = VARCHAR), UNION(code = INTEGER, label = VARCHAR)))
  expect_equal(DBI::dbGetQuery(con, "SELECT union_extract(rducks_union_arrow_c(union_value(code := 42)::UNION(code INTEGER, label VARCHAR)), 'label') AS x")$x, "c42")
  union_explain <- rducks_explain_udf(con, "rducks_union_arrow_c")
  expect_equal(union_explain$evaluator, "RC")
  expect_true(union_explain$arrow_c_chunks >= 1)
  expect_equal(union_explain$arrow_r_chunks, 0)
})
