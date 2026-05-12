library(Rducks)

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
  on.exit({
    try(rducks_release(con), silent = TRUE)
    DBI::dbDisconnect(con, shutdown = TRUE)
  }, add = TRUE)
  rducks_enable(con, threads = "single")

  reg <- rducks_register_table(
    con,
    "rducks_table_basic",
    function() data.frame(i = 1:3, label = c("a", "b", "c")),
    returns = list(i = INTEGER, label = VARCHAR),
    chunk_size = 2L
  )
  expect_true(inherits(reg, "rducks_table_registration"))
  expect_equal(reg$spec$chunk_size, 2L)
  release_before <- rducks_release_stats(con)$released[[1L]]
  out <- DBI::dbGetQuery(con, "SELECT * FROM rducks_table_basic() ORDER BY i")
  expect_equal(out$i, 1:3)
  expect_equal(out$label, c("a", "b", "c"))
  release_after <- rducks_release_stats(con)$released[[1L]]
  expect_true(release_after >= release_before + 1)

  invisible(rducks_register_table(
    con,
    "rducks_table_multichunk",
    function() data.frame(i = 1:5),
    returns = list(i = INTEGER),
    chunk_size = 2L
  ))
  multi <- DBI::dbGetQuery(con, "SELECT * FROM rducks_table_multichunk() ORDER BY i")
  expect_equal(multi$i, 1:5)

  invisible(rducks_register_table(
    con,
    "rducks_table_empty",
    function() data.frame(i = integer(), label = character()),
    returns = list(i = INTEGER, label = VARCHAR),
    chunk_size = 2L
  ))
  empty <- DBI::dbGetQuery(con, "SELECT * FROM rducks_table_empty()")
  expect_equal(nrow(empty), 0L)
  expect_equal(names(empty), c("i", "label"))

  invisible(rducks_register_table(
    con,
    "rducks_table_missing_column",
    function() data.frame(j = 1:2),
    returns = list(i = INTEGER),
    chunk_size = 2L
  ))
  expect_error(
    DBI::dbGetQuery(con, "SELECT * FROM rducks_table_missing_column()"),
    "missing output column i"
  )

  invisible(rducks_register_table(
    con,
    "rducks_table_bad_lengths",
    function() list(i = 1:2, label = c("a", "b", "c")),
    returns = list(i = INTEGER, label = VARCHAR),
    chunk_size = 2L
  ))
  expect_error(
    DBI::dbGetQuery(con, "SELECT * FROM rducks_table_bad_lengths()"),
    "equal lengths"
  )

  invisible(rducks_register_table(
    con,
    "rducks_table_error",
    function() stop("table boom", call. = FALSE),
    returns = list(i = INTEGER),
    chunk_size = 2L
  ))
  expect_error(
    DBI::dbGetQuery(con, "SELECT * FROM rducks_table_error()"),
    "table boom"
  )

  expect_error(
    rducks_register_table(con, "rducks_table_bad_schema", function() data.frame(i = 1L), returns = list(INTEGER)),
    "named list"
  )
  expect_error(
    rducks_register_table(con, "rducks_table_bad_chunk", function() data.frame(i = 1L), returns = list(i = INTEGER), chunk_size = 0L),
    "chunk_size"
  )
})
