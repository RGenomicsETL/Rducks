library(Rducks)

rducks_agg_pack <- function(x) serialize(x, NULL, version = 2)
rducks_agg_unpack <- function(state, default) {
  if (is.null(state)) default else unserialize(state)
}

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  update_sum <- function(state, x) {
    s <- rducks_agg_unpack(state, list(sum = 0L, n = 0L))
    s$sum <- as.integer(s$sum + x)
    s$n <- as.integer(s$n + 1L)
    rducks_agg_pack(s)
  }
  combine_sum <- function(left, right) {
    l <- rducks_agg_unpack(left, list(sum = 0L, n = 0L))
    r <- rducks_agg_unpack(right, list(sum = 0L, n = 0L))
    rducks_agg_pack(list(sum = as.integer(l$sum + r$sum), n = as.integer(l$n + r$n)))
  }
  finalize_sum <- function(state) {
    s <- rducks_agg_unpack(state, list(sum = 0L, n = 0L))
    if (identical(s$n, 0L)) NA_integer_ else as.integer(s$sum)
  }

  reg <- rducks_register_aggregate(
    con,
    "rducks_r_sum_i32",
    update_sum,
    finalize_sum,
    INTEGER,
    INTEGER,
    combine = combine_sum
  )
  expect_inherits(reg, "rducks_aggregate_registration")
  expect_equal(reg$spec$signature, "rducks_r_sum_i32(INTEGER) -> INTEGER")

  out <- DBI::dbGetQuery(
    con,
    "SELECT rducks_r_sum_i32(i) AS s FROM (VALUES (1::INTEGER), (2::INTEGER), (NULL::INTEGER), (4::INTEGER)) t(i)"
  )
  expect_equal(out$s, 7L)

  grouped <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT g, rducks_r_sum_i32(i) AS s",
      "FROM (VALUES (1, NULL::INTEGER), (1, NULL::INTEGER), (2, 5::INTEGER), (2, NULL::INTEGER)) t(g, i)",
      "GROUP BY g ORDER BY g"
    )
  )
  expect_equal(grouped$g, c(1, 2))
  expect_true(is.na(grouped$s[[1L]]))
  expect_equal(grouped$s[[2L]], 5L)
})

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  seen_nulls <- 0L
  update_special <- function(state, x) {
    s <- rducks_agg_unpack(state, list(total = 0, nulls = 0L))
    if (is.na(x)) {
      s$nulls <- s$nulls + 1L
    } else {
      s$total <- s$total + x
    }
    seen_nulls <<- s$nulls
    rducks_agg_pack(s)
  }
  finalize_special <- function(state) {
    s <- rducks_agg_unpack(state, list(total = 0, nulls = 0L))
    s$total + s$nulls * 100
  }

  invisible(rducks_register_aggregate(
    con,
    "rducks_r_sum_special",
    update_special,
    finalize_special,
    DOUBLE,
    DOUBLE,
    null_handling = "special"
  ))
  out <- DBI::dbGetQuery(
    con,
    "SELECT rducks_r_sum_special(x) AS s FROM (VALUES (1.5::DOUBLE), (NULL::DOUBLE), (2.5::DOUBLE)) t(x)"
  )
  expect_equal(out$s, 104)
  expect_equal(seen_nulls, 1L)
})

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  bad_update <- function(state, x) {
    if (identical(x, 2L)) stop("aggregate update boom")
    rducks_agg_pack(x)
  }
  invisible(rducks_register_aggregate(con, "rducks_r_bad_update", bad_update, function(state) 1L, INTEGER, INTEGER))
  expect_error(
    DBI::dbGetQuery(con, "SELECT rducks_r_bad_update(i) AS x FROM (VALUES (1::INTEGER), (2::INTEGER)) t(i)"),
    "aggregate update boom"
  )

  bad_finalize <- function(state) stop("aggregate finalize boom")
  invisible(rducks_register_aggregate(con, "rducks_r_bad_finalize", function(state, x) rducks_agg_pack(x), bad_finalize, INTEGER, INTEGER))
  expect_error(
    DBI::dbGetQuery(con, "SELECT rducks_r_bad_finalize(1::INTEGER) AS x"),
    "aggregate finalize boom"
  )
})

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  DBI::dbExecute(con, "PRAGMA threads=2")
  expect_error(
    rducks_register_aggregate(con, "rducks_r_parallel_reject", function(state, x) raw(), function(state) 0L, INTEGER, INTEGER),
    "R-backed functions require DuckDB to execute R code on the calling R thread"
  )
})
