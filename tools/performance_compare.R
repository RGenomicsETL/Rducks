#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) {
  stop("usage: performance_compare.R <baseline.csv> <current.csv>", call. = FALSE)
}

read_num_env <- function(name, default) {
  value <- suppressWarnings(as.numeric(Sys.getenv(name, unset = NA_character_)))
  if (length(value) != 1L || is.na(value) || !is.finite(value) || value <= 0) default else value
}

max_ratio <- read_num_env("RDUCKS_PERF_MAX_RATIO", 1.50)
min_abs_delta <- read_num_env("RDUCKS_PERF_MIN_ABS_DELTA_SEC", 0.50)

baseline <- utils::read.csv(args[[1L]], stringsAsFactors = FALSE)
current <- utils::read.csv(args[[2L]], stringsAsFactors = FALSE)
required <- c("plan", "elapsed_sec")
if (!all(required %in% names(baseline)) || !all(required %in% names(current))) {
  stop("performance CSVs must contain columns: ", paste(required, collapse = ", "), call. = FALSE)
}

merged <- merge(
  baseline[, required],
  current[, required],
  by = "plan",
  suffixes = c("_baseline", "_current"),
  all = FALSE
)
if (!nrow(merged)) {
  stop("no overlapping plans in performance CSVs", call. = FALSE)
}

merged$delta_sec <- merged$elapsed_sec_current - merged$elapsed_sec_baseline
merged$ratio <- merged$elapsed_sec_current / pmax(merged$elapsed_sec_baseline, .Machine$double.eps)
merged$regressed <- merged$delta_sec > min_abs_delta & merged$ratio > max_ratio

print(merged, row.names = FALSE)

out <- Sys.getenv("RDUCKS_PERF_COMPARE_OUTPUT", unset = "")
if (nzchar(out)) {
  utils::write.csv(merged, out, row.names = FALSE)
}

if (any(merged$regressed)) {
  offenders <- paste(
    sprintf(
      "%s current %.3fs vs baseline %.3fs (%.2fx, %+0.3fs)",
      merged$plan[merged$regressed],
      merged$elapsed_sec_current[merged$regressed],
      merged$elapsed_sec_baseline[merged$regressed],
      merged$ratio[merged$regressed],
      merged$delta_sec[merged$regressed]
    ),
    collapse = "; "
  )
  stop(
    "Rducks performance regression detected: ", offenders,
    "; limits are ratio <= ", max_ratio,
    " or absolute delta <= ", min_abs_delta, "s",
    call. = FALSE
  )
}
