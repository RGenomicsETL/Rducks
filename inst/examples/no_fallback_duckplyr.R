# Demo: duckplyr with no fallback, using Rducks for custom R logic.
#
# The important pieces are:
# - duckplyr::read_sql_duckdb(..., prudence = "stingy") forbids dplyr fallback.
# - A plain R helper in mutate() therefore fails, as expected.
# - Registering that logic as a Rducks DuckDB scalar UDF lets duckplyr call it
#   through the dd$ escape hatch, so the pipeline stays in DuckDB.

Sys.setenv(
  DUCKPLYR_FALLBACK_COLLECT = "0",
  DUCKPLYR_FALLBACK_INFO = "0",
  DUCKPLYR_FALLBACK_AUTOUPLOAD = "0"
)

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

local_score <- function(x) x + 100
fallback_blocked <- tryCatch({
  stingy |>
    mutate(score = local_score(x)) |>
    collect()
  FALSE
}, error = function(e) {
  message("Fallback blocked as expected: ", conditionMessage(e))
  TRUE
})
stopifnot(isTRUE(fallback_blocked))

invisible(Rducks::rducks_register_scalar_udf(
  con,
  "rducks_demo_score",
  function(x, label) {
    bonus <- if (identical(label, "high")) 100 else if (identical(label, "mid")) 10 else 0
    as.double(x + bonus)
  },
  args = list(DOUBLE, VARCHAR),
  returns = DOUBLE
))

out <- stingy |>
  mutate(score = dd$rducks_demo_score(x, label)) |>
  filter(score >= 100) |>
  select(id, label, score) |>
  arrange(id) |>
  collect()

print(out)
stopifnot(
  identical(out$id, 5:6),
  identical(out$label, c("high", "high")),
  identical(out$score, c(121, 134))
)
