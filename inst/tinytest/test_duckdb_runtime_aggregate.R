library(Rducks)

rducks_agg_state <- function(sum = 0L, n = 0L) {
  state <- new.env(parent = emptyenv())
  state$sum <- sum
  state$n <- n
  state
}

rducks_agg_add <- function(state, x) {
  if (is.null(state)) state <- rducks_agg_state()
  state$sum <- as.integer(state$sum + x)
  state$n <- as.integer(state$n + 1L)
  state
}

rducks_agg_merge <- function(left, right) {
  if (is.null(right)) return(left)
  if (is.null(left)) left <- rducks_agg_state()
  left$sum <- as.integer(left$sum + right$sum)
  left$n <- as.integer(left$n + right$n)
  left
}

rducks_agg_finish <- function(state) {
  if (is.null(state) || identical(state$n, 0L)) NA_integer_ else as.integer(state$sum)
}

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  update_sum <- function(state, x) rducks_agg_add(state, x)
  combine_sum <- function(left, right) rducks_agg_merge(left, right)
  finalize_sum <- function(state) rducks_agg_finish(state)

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

  update_empty_raw <- function(state, x) {
    if (is.null(state)) raw(0) else state
  }
  finalize_empty_raw <- function(state) {
    if (is.null(state)) -1L else as.integer(length(state))
  }
  invisible(rducks_register_aggregate(
    con,
    "rducks_r_empty_raw_state",
    update_empty_raw,
    finalize_empty_raw,
    INTEGER,
    INTEGER
  ))
  out <- DBI::dbGetQuery(
    con,
    "SELECT rducks_r_empty_raw_state(i) AS n FROM (VALUES (1::INTEGER), (2::INTEGER)) t(i)"
  )
  expect_equal(out$n, 0L)
})

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  update_chunk_calls <- 0L
  update_row_calls <- 0L
  saw_skipped_row <- FALSE
  update_chunk_sum <- function(states, group_id, x) {
    update_chunk_calls <<- update_chunk_calls + 1L
    saw_skipped_row <<- saw_skipped_row || any(group_id == 0L)
    for (g in seq_along(states)) {
      rows <- which(group_id == g)
      state <- states[[g]]
      if (is.null(state)) state <- rducks_agg_state()
      state$sum <- as.integer(state$sum + sum(x[rows]))
      state$n <- as.integer(state$n + length(rows))
      states[[g]] <- state
    }
    states
  }
  update_row_fallback <- function(state, x) {
    update_row_calls <<- update_row_calls + 1L
    rducks_agg_add(state, x)
  }
  finalize_chunk_sum <- function(states) {
    vapply(states, rducks_agg_finish, integer(1))
  }

  invisible(rducks_register_aggregate(
    con,
    "rducks_r_sum_i32_chunk",
    update = update_row_fallback,
    finalize = function(state) -999L,
    args = INTEGER,
    returns = INTEGER,
    update_chunk = update_chunk_sum,
    finalize_chunk = finalize_chunk_sum
  ))
  chunked <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT g, rducks_r_sum_i32_chunk(i) AS s",
      "FROM (VALUES (1, 1::INTEGER), (1, 2::INTEGER), (1, NULL::INTEGER),",
      "             (2, 5::INTEGER), (2, 7::INTEGER)) t(g, i)",
      "GROUP BY g ORDER BY g"
    )
  )
  expect_equal(chunked$g, c(1, 2))
  expect_equal(chunked$s, c(3L, 12L))
  expect_true(update_chunk_calls >= 1L)
  expect_equal(update_row_calls, 0L)
  expect_true(saw_skipped_row)
})

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  seen_nulls <- 0L
  update_special <- function(state, x) {
    if (is.null(state)) {
      state <- new.env(parent = emptyenv())
      state$total <- 0
      state$nulls <- 0L
    }
    if (is.na(x)) {
      state$nulls <- state$nulls + 1L
    } else {
      state$total <- state$total + x
    }
    seen_nulls <<- state$nulls
    state
  }
  finalize_special <- function(state) {
    if (is.null(state)) return(NA_real_)
    state$total + state$nulls * 100
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

  update_env <- function(state, x) {
    if (is.null(state)) {
      state <- new.env(parent = emptyenv())
      state$sum <- 0L
      state$n <- 0L
    }
    state$sum <- as.integer(state$sum + x)
    state$n <- as.integer(state$n + 1L)
    state
  }
  finalize_env <- function(state) {
    if (is.null(state) || identical(state$n, 0L)) NA_integer_ else state$sum
  }

  invisible(rducks_register_aggregate(
    con,
    "rducks_r_sum_env_state",
    update_env,
    finalize_env,
    INTEGER,
    INTEGER
  ))
  out <- DBI::dbGetQuery(
    con,
    "SELECT rducks_r_sum_env_state(i) AS s FROM (VALUES (10::INTEGER), (20::INTEGER), (NULL::INTEGER)) t(i)"
  )
  expect_equal(out$s, 30L)
})

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  bad_update <- function(state, x) {
    if (identical(x, 2L)) stop("aggregate update boom")
    x
  }
  invisible(rducks_register_aggregate(con, "rducks_r_bad_update", bad_update, function(state) 1L, INTEGER, INTEGER))
  expect_error(
    DBI::dbGetQuery(con, "SELECT rducks_r_bad_update(i) AS x FROM (VALUES (1::INTEGER), (2::INTEGER)) t(i)"),
    "aggregate update boom"
  )

  bad_finalize <- function(state) stop("aggregate finalize boom")
  invisible(rducks_register_aggregate(con, "rducks_r_bad_finalize", function(state, x) x, bad_finalize, INTEGER, INTEGER))
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
    rducks_register_aggregate(con, "rducks_r_parallel_reject", function(state, x) x, function(state) 0L, INTEGER, INTEGER),
    "R-backed functions require DuckDB to execute R code on the calling R thread"
  )
})
