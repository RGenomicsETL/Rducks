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
  post_eof <- rducks_query_stream(con, "SELECT 10::INTEGER AS i", batch_size = 2L)
  expect_equal(post_eof$next_batch()$i, 10L)
  expect_true(isTRUE(post_eof$close()))
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

  held <- rducks_query_stream(con, "SELECT i::INTEGER AS i FROM range(1, 4) t(i)", batch_size = 2L)
  expect_error(
    rducks_query_stream(con, "SELECT i::INTEGER AS i FROM range(10, 12) t(i)", batch_size = 2L),
    "one active native query stream"
  )
  expect_equal(held$next_batch()$i, 1:2)
  expect_true(isTRUE(held$close()))

  reg_after_stream <- rducks_register_scalar_udf(
    con,
    "r_after_stream_plus_one",
    function(x) x + 1,
    DOUBLE,
    DOUBLE
  )
  expect_inherits(reg_after_stream, "rducks_scalar_udf_registration")
  expect_equal(DBI::dbGetQuery(con, "SELECT r_after_stream_plus_one(1.0) AS x")$x, 2)

  table_after_stream <- rducks_register_table(
    con,
    "r_after_stream_table",
    function() data.frame(i = 1:3),
    chunk_size = 2L
  )
  expect_inherits(table_after_stream, "rducks_table_registration")
  expect_equal(DBI::dbGetQuery(con, "SELECT sum(i) AS s FROM r_after_stream_table()")$s, 6)

  aggregate_after_stream <- rducks_register_aggregate(
    con,
    "r_after_stream_count_i32",
    update = function(state, x) as.integer((if (is.null(state)) 0L else state) + 1L),
    finalize = function(state) as.integer(if (is.null(state)) 0L else state),
    INTEGER,
    INTEGER,
    combine = function(left, right) as.integer((if (is.null(left)) 0L else left) + (if (is.null(right)) 0L else right))
  )
  expect_inherits(aggregate_after_stream, "rducks_aggregate_registration")
  expect_equal(
    DBI::dbGetQuery(con, "SELECT r_after_stream_count_i32(i) AS n FROM (VALUES (1::INTEGER), (2::INTEGER), (3::INTEGER)) t(i)")$n,
    3L
  )

  exotic <- rducks_query_stream(
    con,
    paste(
      "SELECT 12.34::DECIMAL(8,2) AS dec,",
      "'123e4567-e89b-12d3-a456-426614174000'::UUID AS id,",
      "blob 'abc' AS payload,",
      "[1,2,3]::INTEGER[] AS ints,",
      "{'a': 1::INTEGER, 'b': 'x'::VARCHAR} AS rec,",
      "MAP(['a','b'], [1,2]) AS lookup"
    ),
    batch_size = 1L
  )
  exotic_batch <- exotic$next_batch()
  expect_true(inherits(exotic_batch$dec, "rducks_decimal"))
  expect_equal(as.character(exotic_batch$dec), "12.34")
  expect_true(inherits(exotic_batch$id, "rducks_uuid"))
  expect_equal(as.character(exotic_batch$id), "123e4567-e89b-12d3-a456-426614174000")
  expect_equal(exotic_batch$payload[[1L]], charToRaw("abc"))
  expect_equal(exotic_batch$ints[[1L]], 1:3)
  expect_equal(exotic_batch$rec[[1L]], list(a = 1L, b = "x"))
  expect_equal(exotic_batch$lookup[[1L]], list(keys = c("a", "b"), values = 1:2))
  expect_null(exotic$next_batch())
  expect_true(isTRUE(exotic$close()))

  union_stream <- rducks_query_stream(
    con,
    "SELECT union_value(code := 42::INTEGER)::UNION(code INTEGER, label VARCHAR) AS choice",
    batch_size = 2L
  )
  union_batch <- union_stream$next_batch()
  expect_equal(union_batch$choice[[1L]]$tag, "code")
  expect_equal(union_batch$choice[[1L]]$value, 42L)
  expect_null(union_stream$next_batch())
  expect_true(isTRUE(union_stream$close()))

  rb_stream <- rducks_query_stream(
    con,
    "SELECT i::INTEGER AS i, ('row-' || i::VARCHAR) AS label FROM range(1, 5) t(i) ORDER BY i",
    batch_size = 2L,
    format = "record_batch"
  )
  rb_first <- rb_stream$next_batch()
  expect_true(inherits(rb_first, "nanoarrow_array"))
  expect_true(inherits(nanoarrow::infer_nanoarrow_schema(rb_first), "nanoarrow_schema"))
  expect_true(identical(attr(rb_first, "rducks_nanoarrow_schema"), rb_stream$schema))
  expect_equal(as.data.frame(rb_first)$i, 1:2)
  rb_second <- rb_stream$next_batch(format = "nanoarrow")
  expect_true(inherits(rb_second, "nanoarrow_array"))
  expect_equal(as.data.frame(rb_second)$i, 3:4)
  expect_null(rb_stream$next_batch())
  expect_true(isTRUE(rb_stream$close()))

  enum_stream <- rducks_query_stream(
    con,
    "SELECT v::ENUM('a', 'b') AS e FROM (VALUES ('a'), ('b')) t(v) ORDER BY v",
    batch_size = 2L,
    format = "record_batch"
  )
  enum_batch <- enum_stream$next_batch()
  expect_true(inherits(enum_batch, "nanoarrow_array"))
  expect_equal(as.character(as.data.frame(enum_batch)$e), c("a", "b"))
  expect_null(enum_stream$next_batch())
  expect_true(isTRUE(enum_stream$close()))

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
