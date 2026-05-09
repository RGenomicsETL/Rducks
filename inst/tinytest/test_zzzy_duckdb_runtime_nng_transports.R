library(Rducks)

helper <- system.file("tinytest", "helper_nng_transports.R", package = "Rducks")

for (transport in Rducks:::rducks_nng_runtime_transports()) {
  child_test <- tempfile(paste0("rducks-nng-transport-", transport, "-"), fileext = ".R")
  writeLines(c(
    "library(Rducks)",
    sprintf("source(%s, local = TRUE)", deparse(helper)),
    sprintf("rducks_nng_transports_body(%s)", deparse(transport)),
    "invisible(gc())",
    "Sys.sleep(0.2)"
  ), child_test)

  script <- sprintf(
    paste(
      "res <- tinytest::run_test_file(%s)",
      "if (!tinytest::all_pass(res)) quit(status = 1L, save = 'no')",
      sep = "; "
    ),
    deparse(child_test)
  )
  output <- tempfile(paste0("rducks-nng-transport-", transport, "-"), fileext = ".log")
  status <- system2(
    file.path(R.home("bin"), "Rscript"),
    c("--vanilla", "-e", shQuote(script)),
    stdout = output,
    stderr = output
  )
  if (!identical(status, 0L) && file.exists(output)) {
    cat(paste(readLines(output, warn = FALSE), collapse = "\n"), "\n", sep = "")
  }
  expect_equal(status, 0L)
}
