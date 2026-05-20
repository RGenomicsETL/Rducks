library(Rducks)

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit({
    try(rducks_release(con), silent = TRUE)
    DBI::dbDisconnect(con, shutdown = TRUE)
  }, add = TRUE)
  rducks_enable(con, threads = "single")

  env <- new.env(parent = baseenv())
  env$sentinel <- 41L
  expect_equal(with(con, sentinel + 1L, rducks_env = env), 42L)
  expect_error(
    Rducks:::rducks_duckplyr_register_udfs(
      con,
      list(missing_duckplyr_udf = INTEGER),
      env,
      null_handling = "default",
      exception_handling = "rethrow",
      side_effects = FALSE
    ),
    "cannot find R function"
  )
})

local({
  old_collect <- Sys.getenv("DUCKPLYR_FALLBACK_COLLECT", unset = NA_character_)
  old_info <- Sys.getenv("DUCKPLYR_FALLBACK_INFO", unset = NA_character_)
  old_upload <- Sys.getenv("DUCKPLYR_FALLBACK_AUTOUPLOAD", unset = NA_character_)
  Sys.setenv(
    DUCKPLYR_FALLBACK_COLLECT = "0",
    DUCKPLYR_FALLBACK_INFO = "0",
    DUCKPLYR_FALLBACK_AUTOUPLOAD = "0"
  )
  on.exit({
    if (is.na(old_collect)) Sys.unsetenv("DUCKPLYR_FALLBACK_COLLECT") else Sys.setenv(DUCKPLYR_FALLBACK_COLLECT = old_collect)
    if (is.na(old_info)) Sys.unsetenv("DUCKPLYR_FALLBACK_INFO") else Sys.setenv(DUCKPLYR_FALLBACK_INFO = old_info)
    if (is.na(old_upload)) Sys.unsetenv("DUCKPLYR_FALLBACK_AUTOUPLOAD") else Sys.setenv(DUCKPLYR_FALLBACK_AUTOUPLOAD = old_upload)
  }, add = TRUE)

  if (!requireNamespace("duckplyr", quietly = TRUE) ||
      !requireNamespace("dplyr", quietly = TRUE) ||
      !requireNamespace("duckdb", quietly = TRUE)) {
    return(invisible(NULL))
  }

  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit({
    try(rducks_release(con), silent = TRUE)
    DBI::dbDisconnect(con, shutdown = TRUE)
  }, add = TRUE)
  rducks_enable(con, threads = "single")

  DBI::dbWriteTable(con, "duckplyr_input", data.frame(
    id = 1:4,
    x = as.numeric(c(2, 8, 21, 34)),
    label = c("low", "mid", "high", "high")
  ))

  df <- duckplyr::read_sql_duckdb("SELECT * FROM duckplyr_input", con = con, prudence = "stingy")
  local_score <- function(x, label) {
    bonus <- if (identical(label, "high")) 100 else if (identical(label, "mid")) 10 else 0
    as.double(x + bonus)
  }

  blocked <- try(
    df |>
      dplyr::mutate(score = local_score(x, label)) |>
      dplyr::collect(),
    silent = TRUE
  )
  expect_true(inherits(blocked, "try-error"))

  out <- rducks_with_duckplyr(
    con,
    df |>
      dplyr::mutate(score = local_score(x, label)) |>
      dplyr::filter(score >= 100) |>
      dplyr::select(id, label, score) |>
      dplyr::arrange(id) |>
      dplyr::collect(),
    returns = list(local_score = DOUBLE)
  )
  expect_equal(out$id, 3:4)
  expect_equal(out$label, c("high", "high"))
  expect_equal(out$score, c(121, 134))

  out_with <- with(
    con,
    df |>
      dplyr::mutate(score = local_score(x, label)) |>
      dplyr::filter(score >= 100) |>
      dplyr::select(id, label, score) |>
      dplyr::arrange(id) |>
      dplyr::collect(),
    rducks_returns = list(local_score = DOUBLE)
  )
  expect_equal(out_with, out)

  local_score_vec <- function(x, label) {
    as.double(x + ifelse(label == "high", 100, ifelse(label == "mid", 10, 0)))
  }
  out_vec <- rducks_with_duckplyr(
    con,
    df |>
      dplyr::mutate(score = local_score_vec(x, label)) |>
      dplyr::filter(score >= 100) |>
      dplyr::select(id, label, score) |>
      dplyr::arrange(id) |>
      dplyr::collect(),
    returns = list(local_score_vec = DOUBLE),
    mode = "vectorized"
  )
  expect_equal(out_vec, out)

  local_score_with_vec <- local_score_vec
  out_with_vec <- with(
    con,
    df |>
      dplyr::mutate(score = local_score_with_vec(x, label)) |>
      dplyr::filter(score >= 100) |>
      dplyr::select(id, label, score) |>
      dplyr::arrange(id) |>
      dplyr::collect(),
    rducks_returns = list(local_score_with_vec = DOUBLE),
    rducks_mode = "vectorized"
  )
  expect_equal(out_with_vec, out)
})
