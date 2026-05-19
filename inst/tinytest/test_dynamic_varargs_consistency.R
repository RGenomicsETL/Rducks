library(Rducks)

# These are intentionally aspirational consistency tests. They document the
# desired API direction for omitted `args`: a dynamic-argument scalar UDF should
# behave like an explicitly typed scalar UDF after DuckDB has bound the concrete
# argument types. Several expectations fail today and should start passing as the
# API is made consistent across execution plans and type families.

rducks_dynamic_consistency_connection <- function() {
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
  rducks_enable(con, threads = "single")
  con
}

rducks_expect_no_try_error <- function(value, info) {
  ok <- !inherits(value, "try-error")
  expect_true(ok, info = info)
  ok
}

local({
  con <- rducks_dynamic_consistency_connection()
  on.exit({
    try(rducks_release(con), silent = TRUE)
    try(Rducks:::rducks_nng_stop_all_providers(quiet = TRUE), silent = TRUE)
    try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE)
  }, add = TRUE)

  plans <- list(
    arrow_r_serial = rducks_execution_plan("arrow_r", "serial"),
    arrow_r_inproc = rducks_execution_plan("arrow_r", "inproc_concurrent"),
    arrow_c_serial = rducks_execution_plan("arrow_c", "serial"),
    arrow_c_inproc = rducks_execution_plan("arrow_c", "inproc_concurrent"),
    arrow_ipc = rducks_execution_plan(
      "arrow_ipc", "multiprocess_parallel",
      ipc_workers = 1L,
      ipc_transport = "tcp",
      ipc_timeout = 30
    )
  )

  for (plan_name in names(plans)) {
    plan <- plans[[plan_name]]
    fn_name <- paste0("dyn_plan_", plan_name)
    result <- try({
      rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
      invisible(rducks_register_scalar_udf(
        con,
        fn_name,
        function(x) as.double(x) + 1,
        returns = DOUBLE,
        side_effects = TRUE
      ))
      DBI::dbGetQuery(con, sprintf("SELECT %s(41::DOUBLE) AS x", fn_name))$x[[1L]]
    }, silent = TRUE)

    if (rducks_expect_no_try_error(
      result,
      sprintf("dynamic args should register and execute under %s", plan$plan_id)
    )) {
      expect_equal(result, 42, info = sprintf("dynamic args result under %s", plan$plan_id))
    }
  }
})

local({
  con <- rducks_dynamic_consistency_connection()
  on.exit({
    try(rducks_release(con), silent = TRUE)
    try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE)
  }, add = TRUE)

  result <- try({
    invisible(rducks_register_scalar_udf(
      con,
      "dyn_vectorized_plus_one",
      function(x) x + 1,
      returns = DOUBLE,
      mode = "vectorized",
      side_effects = TRUE
    ))
    DBI::dbGetQuery(con, "SELECT dyn_vectorized_plus_one(i::DOUBLE) AS x FROM range(3) t(i)")$x
  }, silent = TRUE)

  if (rducks_expect_no_try_error(
    result,
    "dynamic args should support vectorized scalar-UDF mode after DuckDB binding"
  )) {
    expect_equal(result, c(1, 2, 3), info = "dynamic vectorized result")
  }
})

local({
  old_warn <- getOption("nanoarrow.warn_unregistered_extension")
  options(nanoarrow.warn_unregistered_extension = FALSE)
  on.exit(options(nanoarrow.warn_unregistered_extension = old_warn), add = TRUE)

  con <- rducks_dynamic_consistency_connection()
  on.exit({
    try(rducks_release(con), silent = TRUE)
    try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE)
  }, add = TRUE)

  class_string <- function(x) paste(class(x), collapse = "/")
  cases <- list(
    uuid = list(
      type = UUID,
      sql = "'550e8400-e29b-41d4-a716-446655440000'::UUID",
      expected_class = "rducks_uuid"
    ),
    hugeint = list(
      type = HUGEINT,
      sql = "170141183460469231731687303715884105726::HUGEINT",
      expected_class = "rducks_hugeint"
    ),
    decimal = list(
      type = DECIMAL(10, 2),
      sql = "12.34::DECIMAL(10,2)",
      expected_class = "rducks_decimal"
    ),
    interval = list(
      type = INTERVAL,
      sql = "INTERVAL '2 days'",
      expected_class = "rducks_interval"
    ),
    bit = list(
      type = BIT,
      sql = "'1010'::BIT",
      expected_class = "rducks_bits"
    ),
    enum = list(
      type = ENUM(c("red", "blue")),
      sql = "'red'::ENUM('red','blue')",
      expected_class = "rducks_enum"
    ),
    union = list(
      type = UNION(code = INTEGER, label = VARCHAR),
      sql = "union_value(code := 42)::UNION(code INTEGER, label VARCHAR)",
      expected_class = "rducks_union"
    )
  )

  for (case_name in names(cases)) {
    case <- cases[[case_name]]
    fn_name <- paste0("declared_class_", case_name)
    invisible(rducks_register_scalar_udf(
      con,
      fn_name,
      class_string,
      args = case$type,
      returns = VARCHAR,
      null_handling = "special"
    ))
    declared_class <- DBI::dbGetQuery(
      con,
      sprintf("SELECT %s(%s) AS x", fn_name, case$sql)
    )$x[[1L]]
    expect_true(
      case$expected_class %in% strsplit(declared_class, "/", fixed = TRUE)[[1L]],
      info = sprintf("declared args preserve %s as %s", case_name, case$expected_class)
    )
  }

  invisible(rducks_register_scalar_udf(
    con,
    "dynamic_class_probe",
    class_string,
    returns = VARCHAR,
    null_handling = "special"
  ))

  for (case_name in names(cases)) {
    case <- cases[[case_name]]
    dynamic_class <- try(DBI::dbGetQuery(
      con,
      sprintf("SELECT dynamic_class_probe(%s) AS x", case$sql)
    )$x[[1L]], silent = TRUE)

    if (rducks_expect_no_try_error(
      dynamic_class,
      sprintf("dynamic args should accept %s inputs", case_name)
    )) {
      expect_true(
        case$expected_class %in% strsplit(dynamic_class, "/", fixed = TRUE)[[1L]],
        info = sprintf(
          "dynamic args should preserve %s as %s; got %s",
          case_name, case$expected_class, dynamic_class
        )
      )
    }
  }
})
