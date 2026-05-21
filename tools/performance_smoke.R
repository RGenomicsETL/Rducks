#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(DBI)
  library(Rducks)
})

read_int_env <- function(name, default) {
  value <- suppressWarnings(as.integer(Sys.getenv(name, unset = NA_character_)))
  if (length(value) != 1L || is.na(value) || value <= 0L) default else value
}

read_num_env <- function(name, default) {
  value <- suppressWarnings(as.numeric(Sys.getenv(name, unset = NA_character_)))
  if (length(value) != 1L || is.na(value) || !is.finite(value) || value <= 0) default else value
}

rows <- read_int_env("RDUCKS_PERF_ROWS", 2048L * 128L)
thresholds <- c(
  arrow_r = read_num_env("RDUCKS_PERF_ARROW_R_MAX_SEC", 8),
  arrow_c = read_num_env("RDUCKS_PERF_ARROW_C_MAX_SEC", 8)
)
enforce_thresholds <- !tolower(Sys.getenv("RDUCKS_PERF_ENFORCE_THRESHOLDS", "true")) %in% c("0", "false", "no")

con <- DBI::dbConnect(
  duckdb::duckdb(config = list(allow_unsigned_extensions = "true")),
  dbdir = ":memory:"
)
on.exit({
  try(Rducks::rducks_release(con), silent = TRUE)
  try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE)
}, add = TRUE)

Rducks::rducks_enable(con, threads = "single")

identity_i32 <- function(x) x
plans <- list(
  arrow_r = Rducks::rducks_execution_plan("arrow_r", "serial"),
  arrow_c = Rducks::rducks_execution_plan("arrow_c", "serial")
)
udfs <- paste0("r_perf_", names(plans))

for (i in seq_along(plans)) {
  Rducks::rducks_set_execution_plan(con, plans[[i]], threads = 1L, external_threads = 1L)
  Rducks::rducks_register_scalar_udf(
    con,
    name = udfs[[i]],
    fun = identity_i32,
    args = Rducks::INTEGER,
    returns = Rducks::INTEGER,
    mode = "vectorized",
    side_effects = TRUE
  )
}

expected_total <- sum(as.integer(seq.int(0L, rows - 1L) %% 1000L))
run_one <- function(label, udf, plan) {
  Rducks::rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
  invisible(DBI::dbGetQuery(con, sprintf(
    "SELECT sum(%s((i %% 1000)::INTEGER)) AS total FROM range(0, 2048) tbl(i)",
    DBI::dbQuoteIdentifier(con, udf)
  )))
  gc(FALSE)
  elapsed <- system.time({
    result <- DBI::dbGetQuery(con, sprintf(
      "SELECT sum(%s((i %% 1000)::INTEGER)) AS total FROM range(0, %d) tbl(i)",
      DBI::dbQuoteIdentifier(con, udf),
      rows
    ))
  })[["elapsed"]]
  total <- as.numeric(result$total[[1L]])
  if (!identical(total, as.numeric(expected_total))) {
    stop(label, " returned total ", total, "; expected ", expected_total, call. = FALSE)
  }
  data.frame(
    plan = label,
    rows = rows,
    elapsed_sec = round(elapsed, 3),
    threshold_sec = thresholds[[label]],
    stringsAsFactors = FALSE
  )
}

results <- do.call(rbind, Map(run_one, names(plans), udfs, plans))
print(results, row.names = FALSE)

output <- Sys.getenv("RDUCKS_PERF_OUTPUT", unset = "")
if (nzchar(output)) {
  utils::write.csv(results, output, row.names = FALSE)
}

slow <- results$elapsed_sec > results$threshold_sec
if (enforce_thresholds && any(slow)) {
  offenders <- paste(
    sprintf("%s %.3fs > %.3fs", results$plan[slow], results$elapsed_sec[slow], results$threshold_sec[slow]),
    collapse = "; "
  )
  stop("Rducks performance smoke threshold exceeded: ", offenders, call. = FALSE)
}
