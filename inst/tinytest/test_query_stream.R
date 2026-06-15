library(Rducks)

local({
  if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE)) {
    exit_file("duckdb/DBI not available")
  }
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  on.exit(rducks_release(con), add = TRUE)

  # Multi-batch, multi-column stream materialized directly from DuckDB vectors.
  stream <- rducks_query_stream(
    con,
    "SELECT i::INTEGER AS i, (i * 1.5)::DOUBLE AS x, ('v' || i::VARCHAR) AS s FROM range(1, 6000) t(i)"
  )
  expect_equal(stream$schema$names, c("i", "x", "s"))

  total <- 0
  nrows <- 0L
  batches <- 0L
  repeat {
    batch <- stream$next_batch()
    if (is.null(batch)) break
    batches <- batches + 1L
    expect_equal(names(batch), c("i", "x", "s"))
    total <- total + sum(batch$i)
    nrows <- nrows + nrow(batch)
  }
  stream$close()

  expect_true(batches >= 1L)
  expect_equal(nrows, 5999L)
  expect_equal(total, sum(1:5999))
  # next_batch() after end-of-stream/close returns NULL.
  expect_null(stream$next_batch())
})
