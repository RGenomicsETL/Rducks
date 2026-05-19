# Demo: duckplyr with no fallback, using Rducks for custom R logic.
#
# The important pieces are:
# - duckplyr::read_sql_duckdb(..., prudence = "stingy") forbids dplyr fallback.
# - A plain R helper in mutate() therefore fails by itself, as expected.
# - with(con, ..., rducks_returns = ...) registers selected R helpers as
#   dynamic-argument DuckDB scalar UDFs and rewrites those calls before duckplyr
#   translates the pipeline, so the expression stays in DuckDB.
# - DuckDB still needs return types at planning time; simple scalar input
#   argument types are intentionally omitted here.

old_collect <- Sys.getenv("DUCKPLYR_FALLBACK_COLLECT", unset = NA_character_)
old_info <- Sys.getenv("DUCKPLYR_FALLBACK_INFO", unset = NA_character_)
old_upload <- Sys.getenv("DUCKPLYR_FALLBACK_AUTOUPLOAD", unset = NA_character_)
Sys.setenv(
  DUCKPLYR_FALLBACK_COLLECT = "0",
  DUCKPLYR_FALLBACK_INFO = "0",
  DUCKPLYR_FALLBACK_AUTOUPLOAD = "0"
)
restore_env <- function(name, value) {
  if (is.na(value)) {
    Sys.unsetenv(name)
  } else {
    do.call(Sys.setenv, stats::setNames(list(value), name))
  }
}
on.exit({
  restore_env("DUCKPLYR_FALLBACK_COLLECT", old_collect)
  restore_env("DUCKPLYR_FALLBACK_INFO", old_info)
  restore_env("DUCKPLYR_FALLBACK_AUTOUPLOAD", old_upload)
}, add = TRUE)

required <- c("DBI", "dplyr", "duckdb", "duckplyr", "Rducks")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) {
  stop("This demo requires packages: ", paste(missing, collapse = ", "), call. = FALSE)
}

suppressPackageStartupMessages({
  library(DBI)
  library(dplyr)
  library(duckdb)
  library(duckplyr)
  library(Rducks)
})

con <- DBI::dbConnect(
  duckdb::duckdb(config = list(allow_unsigned_extensions = "true")),
  dbdir = ":memory:"
)
on.exit({
  try(Rducks::rducks_release(con), silent = TRUE)
  try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE)
}, add = TRUE)

Rducks::rducks_enable(con, threads = "single")

input <- data.frame(
  id = 1:6,
  x = as.numeric(c(2, 5, 8, 13, 21, 34)),
  label = c("low", "low", "mid", "mid", "high", "high")
)
DBI::dbWriteTable(con, "demo_input", input)

stingy <- duckplyr::read_sql_duckdb(
  "SELECT * FROM demo_input",
  con = con,
  prudence = "stingy"
)

local_score <- function(x, label) {
  bonus <- if (identical(label, "high")) 100 else if (identical(label, "mid")) 10 else 0
  as.double(x + bonus)
}

fallback_blocked <- tryCatch({
  stingy |>
    mutate(score = local_score(x, label)) |>
    collect()
  FALSE
}, error = function(e) {
  message("Fallback blocked as expected: ", conditionMessage(e))
  TRUE
})
stopifnot(isTRUE(fallback_blocked))

out <- with(
  con,
  stingy |>
    mutate(score = local_score(x, label)) |>
    filter(score >= 100) |>
    select(id, label, score) |>
    arrange(id) |>
    collect(),
  rducks_returns = list(local_score = DOUBLE)
)

print(out)
stopifnot(
  identical(out$id, 5:6),
  identical(out$label, c("high", "high")),
  identical(out$score, c(121, 134))
)
