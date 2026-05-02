#!/usr/bin/env Rscript

library(DBI)
library(duckdb)
library(Rducks)

con <- dbConnect(duckdb(config = list(allow_unsigned_extensions = "true")))
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
rducks_enable(con, threads = "single")

invisible(rducks_register(con, "bench_eval_r", function(x) x + 1, DOUBLE, DOUBLE,
                          eval_mode = "R", side_effects = TRUE))
invisible(rducks_register(con, "bench_eval_rc", function(x) x + 1, DOUBLE, DOUBLE,
                          eval_mode = "RC", side_effects = TRUE))

for (n in c(10000L, 100000L, 300000L)) {
  invisible(dbGetQuery(con, "SELECT sum(bench_eval_r(i::DOUBLE)) AS x FROM range(1000) t(i)"))
  invisible(dbGetQuery(con, "SELECT sum(bench_eval_rc(i::DOUBLE)) AS x FROM range(1000) t(i)"))

  gc()
  plain <- system.time(dbGetQuery(con, sprintf(
    "SELECT sum(i::DOUBLE + 1) AS x FROM range(%d) t(i)", n
  )))[["elapsed"]]
  gc()
  r_time <- system.time(dbGetQuery(con, sprintf(
    "SELECT sum(bench_eval_r(i::DOUBLE)) AS x FROM range(%d) t(i)", n
  )))[["elapsed"]]
  gc()
  rc_time <- system.time(dbGetQuery(con, sprintf(
    "SELECT sum(bench_eval_rc(i::DOUBLE)) AS x FROM range(%d) t(i)", n
  )))[["elapsed"]]

  cat(sprintf(
    "n=%d plain=%.3fs R=%.3fs RC=%.3fs R_rows/s=%.0f RC_rows/s=%.0f speedup=%.2fx\n",
    n, plain, r_time, rc_time, n / r_time, n / rc_time, r_time / rc_time
  ))
}
