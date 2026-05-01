library(Rducks)

local({
  ns <- asNamespace("Rducks")
  original_factory <- get("rducks_make_arrow_scalar_wrapper", envir = ns)
  chunk_sizes <- integer()
  user_calls <- 0L

  unlockBinding("rducks_make_arrow_scalar_wrapper", ns)
  assign("rducks_make_arrow_scalar_wrapper", function(...) {
    wrapper <- original_factory(...)
    function(input_array, input_schema, output_schema, n) {
      chunk_sizes <<- c(chunk_sizes, as.integer(n))
      wrapper(input_array, input_schema, output_schema, n)
    }
  }, envir = ns)
  lockBinding("rducks_make_arrow_scalar_wrapper", ns)
  on.exit({
    unlockBinding("rducks_make_arrow_scalar_wrapper", ns)
    assign("rducks_make_arrow_scalar_wrapper", original_factory, envir = ns)
    lockBinding("rducks_make_arrow_scalar_wrapper", ns)
  }, add = TRUE)

  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  invisible(rducks_register(
    con,
    "rducks_chunk_probe",
    function(x) {
      user_calls <<- user_calls + 1L
      x
    },
    DOUBLE,
    DOUBLE,
    side_effects = TRUE
  ))

  result <- DBI::dbGetQuery(con, "SELECT sum(rducks_chunk_probe(i::DOUBLE)) AS x FROM range(5000) t(i)")
  expect_equal(result$x, 12497500)
  expect_equal(sum(chunk_sizes), 5000L)
  expect_equal(user_calls, 5000L)
  expect_true(length(chunk_sizes) < user_calls)
  expect_true(max(chunk_sizes) > 1L)
})
