library(Rducks)

local({
  if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE)) {
    exit_file("duckdb/DBI not available")
  }
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  on.exit(rducks_release(con), add = TRUE)

  # Finite multi-column table: direct DuckDB-vector writes.
  rducks_register_table(
    con, "r_rows",
    function(n) data.frame(
      i = seq_len(as.integer(n)),
      x = as.double(seq_len(as.integer(n))) + 0.5,
      s = paste0("v", seq_len(as.integer(n))),
      stringsAsFactors = FALSE
    ),
    chunk_size = 2L
  )
  res <- DBI::dbGetQuery(con, "SELECT i, x, s FROM r_rows(3) ORDER BY i")
  expect_equal(res$i, 1:3)
  expect_equal(res$x, c(1.5, 2.5, 3.5))
  expect_equal(res$s, c("v1", "v2", "v3"))

  # Streaming table via rducks_table_stream(): scan-time batches.
  rducks_register_table(
    con, "r_stream",
    function(n) {
      next_i <- 1L
      limit <- as.integer(n)
      rducks_table_stream(
        prototype = data.frame(i = integer()),
        next_batch = function(batch_size) {
          if (next_i > limit) return(NULL)
          hi <- min(limit, next_i + as.integer(batch_size) - 1L)
          out <- data.frame(i = seq.int(next_i, hi))
          next_i <<- hi + 1L
          out
        }
      )
    },
    chunk_size = 2L
  )
  total <- DBI::dbGetQuery(con, "SELECT sum(i) AS total FROM r_stream(5)")$total
  expect_equal(as.numeric(total), sum(1:5))
})
