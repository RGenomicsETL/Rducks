library(Rducks)

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
  on.exit({
    try(rducks_release(con), silent = TRUE)
    DBI::dbDisconnect(con, shutdown = TRUE)
  }, add = TRUE)
  rducks_enable(con, threads = "single")

  stream <- rducks_query_stream(
    con,
    "SELECT i::INTEGER AS i, ('row-' || i::VARCHAR) AS label FROM range(1, 6) t(i) ORDER BY i",
    batch_size = 2L
  )
  expect_true(inherits(stream, "rducks_query_stream"))
  expect_false(stream$is_closed())
  expect_equal(names(stream$prototype), c("i", "label"))
  expect_true(inherits(stream$schema, "nanoarrow_schema"))

  first <- stream$next_batch()
  expect_equal(nrow(first), 2L)
  expect_equal(first$i, 1:2)
  expect_true(inherits(attr(first, "rducks_nanoarrow_schema"), "nanoarrow_schema"))
  expect_true(identical(attr(first, "rducks_nanoarrow_schema"), stream$schema))

  second <- stream$next_batch()
  expect_equal(second$i, 3:4)
  third <- stream$next_batch()
  expect_equal(third$i, 5L)
  expect_null(stream$next_batch())
  expect_true(isTRUE(stream$close()))
  expect_true(stream$is_closed())

  empty <- rducks_query_stream(con, "SELECT 1::INTEGER AS i WHERE FALSE", batch_size = 2L)
  expect_equal(names(empty$prototype), "i")
  expect_true(inherits(empty$schema, "nanoarrow_schema"))
  expect_null(empty$next_batch())
  expect_true(isTRUE(empty$close()))

  early <- rducks_query_stream(con, "SELECT i::INTEGER AS i FROM range(1, 10) t(i)", batch_size = 3L)
  expect_equal(early$next_batch()$i, 1:3)
  expect_true(isTRUE(early$close()))
  expect_error(early$next_batch(), "closed")
  expect_false(isTRUE(early$close()))

  expect_error(
    rducks_query_stream(con, "SELECT * FROM rducks_missing_stream_table"),
    "rducks_missing_stream_table|Catalog|does not exist"
  )
})

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
  on.exit({
    try(rducks_release(con), silent = TRUE)
    DBI::dbDisconnect(con, shutdown = TRUE)
  }, add = TRUE)
  rducks_enable(con, threads = "single")

  stream <- rducks_query_stream(con, "SELECT i::INTEGER AS i FROM range(1, 5) t(i)", batch_size = 2L)
  expect_equal(stream$next_batch()$i, 1:2)
  rducks_release(con)
  expect_true(stream$is_closed())
  expect_error(stream$next_batch(), "closed")
})
