library(Rducks)

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  rducks_set_execution_plan(con, rducks_execution_plan_internal("direct", "serial"))
  expect_error(
    rducks_register_scalar_udf(con, "rducks_variant_arrow_c", identity, VARIANT, VARIANT),
    "arrow_c direct marshalling is not implemented"
  )
  rducks_set_execution_plan(con, rducks_execution_plan_internal("direct", "serial"))

  unsupported_variant_capi <- "does not expose VARIANT logical types"
  registered <- tryCatch({
    invisible(rducks_register_scalar_udf(con, "rducks_variant_echo", function(x) {
      if (!inherits(x, "rducks_variant")) stop("VARIANT did not materialize as rducks_variant")
      for (field in c("keys", "children", "values", "data")) {
        if (is.null(x[[field]])) stop("VARIANT storage field missing: ", field)
      }
      x
    }, VARIANT, VARIANT))
    TRUE
  }, error = function(e) {
    if (grepl(unsupported_variant_capi, conditionMessage(e), fixed = TRUE)) FALSE else stop(e)
  })

  if (!registered) {
    return(tinytest::exit_file("DuckDB C API VARIANT support is not available in this duckdb build"))
  }

  result <- DBI::dbGetQuery(con, paste0(
    "SELECT ",
    "variant_typeof(rducks_variant_echo(42::VARIANT)) AS int_type, ",
    "variant_typeof(rducks_variant_echo([1, 2, 3]::VARIANT)) AS array_type, ",
    "variant_extract(rducks_variant_echo({'name':'Alice','age':30}::VARIANT), 'name')::VARCHAR AS name"
  ))
  expect_equal(result$int_type, "INT32")
  expect_equal(result$array_type, "ARRAY(3)")
  expect_equal(result$name, "Alice")
})
