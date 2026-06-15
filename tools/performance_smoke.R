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
  direct = read_num_env("RDUCKS_PERF_DIRECT_MAX_SEC", 8),
  quack = read_num_env("RDUCKS_PERF_QUACK_MAX_SEC", 8)
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
Rducks::rducks_set_execution_plan(
  con,
  Rducks:::rducks_execution_plan_internal("direct", "serial"),
  threads = 1L,
  external_threads = 1L
)

identity_i32 <- function(x) x
udf <- "r_perf_direct_i32"
Rducks::rducks_register_scalar_udf(
  con,
  name = udf,
  fun = identity_i32,
  args = Rducks::INTEGER,
  returns = Rducks::INTEGER,
  mode = "vectorized",
  side_effects = TRUE
)

expected_total <- sum(as.integer(seq.int(0L, rows - 1L) %% 1000L))
run_direct <- function() {
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
    stop("direct returned total ", total, "; expected ", expected_total, call. = FALSE)
  }
  data.frame(
    plan = "direct",
    rows = rows,
    elapsed_sec = round(elapsed, 3),
    threshold_sec = thresholds[["direct"]],
    stringsAsFactors = FALSE
  )
}

run_quack <- function() {
  values <- as.integer(seq.int(0L, rows - 1L) %% 1000L)
  gc(FALSE)
  elapsed <- system.time({
    payload <- Rducks:::rducks_wire_encode_values(list(Rducks::INTEGER), list(values), length(values))
    decoded <- Rducks:::rducks_wire_decode_values(list(Rducks::INTEGER), payload)
  })[["elapsed"]]
  if (!identical(decoded$values[[1L]], values)) {
    stop("quack roundtrip returned unexpected values", call. = FALSE)
  }
  data.frame(
    plan = "quack",
    rows = rows,
    elapsed_sec = round(elapsed, 3),
    threshold_sec = thresholds[["quack"]],
    stringsAsFactors = FALSE
  )
}

results <- rbind(run_direct(), run_quack())
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
