#!/usr/bin/env Rscript

library(DBI)
library(duckdb)
library(Rducks)

con_r <- dbConnect(duckdb(config = list(allow_unsigned_extensions = "true")))
con_c <- dbConnect(duckdb(config = list(allow_unsigned_extensions = "true")))
on.exit(dbDisconnect(con_r, shutdown = TRUE), add = TRUE)
on.exit(dbDisconnect(con_c, shutdown = TRUE), add = TRUE)
rducks_enable(con_r, threads = "single")
rducks_enable(con_c, threads = "single")
rducks_set_execution_plan(con_c, rducks_execution_plan("arrow_c", "serial"))

invisible(rducks_register_scalar_udf(con_r, "bench_eval", function(x) x + 1, DOUBLE, DOUBLE,
                          side_effects = TRUE))
invisible(rducks_register_scalar_udf(con_c, "bench_eval", function(x) x + 1, DOUBLE, DOUBLE,
                          side_effects = TRUE))

for (n in c(10000L, 100000L, 300000L)) {
  invisible(dbGetQuery(con_r, "SELECT sum(bench_eval(i::DOUBLE)) AS x FROM range(1000) t(i)"))
  invisible(dbGetQuery(con_c, "SELECT sum(bench_eval(i::DOUBLE)) AS x FROM range(1000) t(i)"))

  gc()
  plain <- system.time(dbGetQuery(con_r, sprintf(
    "SELECT sum(i::DOUBLE + 1) AS x FROM range(%d) t(i)", n
  )))[["elapsed"]]
  gc()
  r_time <- system.time(dbGetQuery(con_r, sprintf(
    "SELECT sum(bench_eval(i::DOUBLE)) AS x FROM range(%d) t(i)", n
  )))[["elapsed"]]
  gc()
  c_time <- system.time(dbGetQuery(con_c, sprintf(
    "SELECT sum(bench_eval(i::DOUBLE)) AS x FROM range(%d) t(i)", n
  )))[["elapsed"]]

  cat(sprintf(
    "n=%d plain=%.3fs arrow_r=%.3fs arrow_c=%.3fs arrow_r_rows/s=%.0f arrow_c_rows/s=%.0f speedup=%.2fx\n",
    n, plain, r_time, c_time, n / r_time, n / c_time, r_time / c_time
  ))
}
