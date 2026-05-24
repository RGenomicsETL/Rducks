Sys.setenv(RDUCKS_DEV_SURFACES = "true")
library(Rducks)

# Consistency tests for omitted `args`: a dynamic-argument scalar UDF should
# behave like an explicitly typed scalar UDF after DuckDB has bound the concrete
# argument types. These use known SQL inputs and exact R outputs, including
# nested/composite values, across marshalling/concurrency plans.

rducks_dynamic_consistency_connection <- function() {
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
  rducks_enable(con, threads = "single")
  con
}

rducks_dynamic_consistency_ipc_transport <- function() {
  transports <- Rducks:::rducks_nng_runtime_transports()
  preferred <- Rducks:::rducks_nng_default_transport()
  if (preferred %in% transports) preferred else transports[[1L]]
}

rducks_expect_no_try_error <- function(value, info) {
  ok <- !inherits(value, "try-error")
  expect_true(ok, info = info)
  ok
}

rducks_dynamic_nested_type <- STRUCT(
  id = INTEGER,
  vals = LIST(INTEGER),
  meta = MAP(VARCHAR, VARCHAR),
  pair = ARRAY(INTEGER, 2),
  choice = UNION(code = INTEGER, label = VARCHAR)
)

rducks_dynamic_nested_duckdb_sql <- paste0(
  "STRUCT(id INTEGER, vals INTEGER[], meta MAP(VARCHAR, VARCHAR), ",
  "pair INTEGER[2], choice UNION(code INTEGER, label VARCHAR))"
)

rducks_dynamic_nested_sql <- function(id = "7") {
  sprintf(
    paste0(
      "struct_pack(",
      "id := %1$s::INTEGER, ",
      "vals := [%1$s::INTEGER, (%1$s + 1)::INTEGER], ",
      "meta := map(['k'], [CAST(%1$s AS VARCHAR)]), ",
      "pair := [%1$s::INTEGER, (%1$s + 2)::INTEGER]::INTEGER[2], ",
      "choice := union_value(label := CAST('v' || %1$s AS VARCHAR))::UNION(code INTEGER, label VARCHAR)",
      ")::%2$s"
    ),
    id,
    rducks_dynamic_nested_duckdb_sql
  )
}

rducks_dynamic_nested_null_sql <- function() {
  paste0("NULL::", rducks_dynamic_nested_duckdb_sql)
}

rducks_dynamic_null_probe <- function(x) {
  if (is.null(x)) "NULL" else "VALUE"
}

rducks_dynamic_delim_struct_sql <- function() {
  "struct_pack(\"a:b\" := 7, \"semi;field\" := 'x')"
}

rducks_dynamic_delim_struct_summary <- function(x) {
  paste0(x[["a:b"]], "|", x[["semi;field"]])
}

rducks_dynamic_nested_summary_one <- function(x) {
  paste0(
    x$id, "|",
    paste(x$vals, collapse = ","), "|",
    paste(paste(x$meta$keys, x$meta$values, sep = "="), collapse = ";"), "|",
    paste(x$pair, collapse = ","), "|",
    x$choice$tag, "=", x$choice$value
  )
}

rducks_dynamic_nested_summary_vec <- function(x) {
  vapply(x, rducks_dynamic_nested_summary_one, character(1))
}

rducks_dynamic_value_string <- function(x) {
  if (inherits(x, "rducks_union")) return(paste0(x$tag, "=", x$value))
  paste(as.character(x), collapse = ",")
}

# Keep managed IPC worker serialization focused on the actual UDF dependency
# graph. Without this, globals auto-discovery captures the whole test-file
# environment, including live DuckDB connection state from prior plan checks.
rducks_dynamic_helper_env <- new.env(parent = baseenv())
for (nm in c(
  "rducks_dynamic_nested_summary_one",
  "rducks_dynamic_nested_summary_vec",
  "rducks_dynamic_null_probe",
  "rducks_dynamic_delim_struct_summary",
  "rducks_dynamic_value_string"
)) {
  assign(nm, get(nm), envir = rducks_dynamic_helper_env)
}
for (nm in ls(rducks_dynamic_helper_env, all.names = TRUE)) {
  fn <- get(nm, envir = rducks_dynamic_helper_env)
  environment(fn) <- rducks_dynamic_helper_env
  assign(nm, fn, envir = rducks_dynamic_helper_env)
  assign(nm, fn)
}

rducks_dynamic_exotic_cases <- list(
  uuid = list(
    type = UUID,
    sql = "'550e8400-e29b-41d4-a716-446655440000'::UUID",
    expected_class = "rducks_uuid",
    expected_value = "550e8400-e29b-41d4-a716-446655440000"
  ),
  hugeint = list(
    type = HUGEINT,
    sql = "170141183460469231731687303715884105726::HUGEINT",
    expected_class = "rducks_hugeint",
    expected_value = "170141183460469231731687303715884105726"
  ),
  decimal = list(
    type = DECIMAL(10, 2),
    sql = "12.34::DECIMAL(10,2)",
    expected_class = "rducks_decimal",
    expected_value = "12.34"
  ),
  interval = list(
    type = INTERVAL,
    sql = "INTERVAL '2 days'",
    expected_class = "rducks_interval",
    expected_value = "0 months 2 days 0 micros"
  ),
  bit = list(
    type = BIT,
    sql = "'1010'::BIT",
    expected_class = "rducks_bits",
    expected_value = "1010"
  ),
  enum = list(
    type = ENUM(c("red", "blue")),
    sql = "'red'::ENUM('red','blue')",
    expected_class = "rducks_enum",
    expected_value = "red"
  ),
  enum_delimiter = list(
    type = ENUM(c("a|b", "semi;colon")),
    sql = "'a|b'::ENUM('a|b','semi;colon')",
    expected_class = "rducks_enum",
    expected_value = "a|b"
  ),
  union = list(
    type = UNION(code = INTEGER, label = VARCHAR),
    sql = "union_value(code := 42)::UNION(code INTEGER, label VARCHAR)",
    expected_class = "rducks_union",
    expected_value = "code=42"
  )
)

local({
  tokens <- c(
    "enum<a%7Cb|semi%3Bcolon>",
    "struct<a%3Ab:i32;semi%3Bfield:varchar>",
    "union<a%3Ab:i32;semi%3Bfield:varchar>"
  )
  for (token in tokens) {
    expect_equal(
      rducks_type_token(Rducks:::rducks_type_from_wire_token(token)),
      token,
      info = paste("dynamic type token round-trip", token)
    )
  }
})

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
      # The consistency matrix exercises dynamic-argument semantics over the
      # real managed NNG/Arrow IPC provider path; transport-specific TCP/IPC/ws
      # coverage lives in test_zzzy_duckdb_runtime_nng_transports.R.
      ipc_transport = rducks_dynamic_consistency_ipc_transport(),
      ipc_timeout = 30,
      ipc_globals = FALSE
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

    nested_fn <- paste0("dyn_nested_", plan_name)
    nested_result <- try({
      invisible(rducks_register_scalar_udf(
        con,
        nested_fn,
        rducks_dynamic_nested_summary_one,
        returns = VARCHAR,
        null_handling = "special",
        side_effects = TRUE
      ))
      DBI::dbGetQuery(
        con,
        sprintf("SELECT %s(%s) AS x", nested_fn, rducks_dynamic_nested_sql("7"))
      )$x[[1L]]
    }, silent = TRUE)

    if (rducks_expect_no_try_error(
      nested_result,
      sprintf("dynamic args should marshal nested scalar inputs under %s", plan$plan_id)
    )) {
      expect_equal(
        nested_result,
        "7|7,8|k=7|7,9|label=v7",
        info = sprintf("dynamic nested scalar result under %s", plan$plan_id)
      )
    }

    null_fn <- paste0("dyn_null_", plan_name)
    null_result <- try({
      invisible(rducks_register_scalar_udf(
        con,
        null_fn,
        rducks_dynamic_null_probe,
        returns = VARCHAR,
        null_handling = "special",
        side_effects = TRUE
      ))
      DBI::dbGetQuery(
        con,
        sprintf("SELECT %s(%s) AS x", null_fn, rducks_dynamic_nested_null_sql())
      )$x[[1L]]
    }, silent = TRUE)

    if (rducks_expect_no_try_error(
      null_result,
      sprintf("dynamic args should preserve special NULL nested inputs under %s", plan$plan_id)
    )) {
      expect_equal(
        null_result,
        "NULL",
        info = sprintf("dynamic special NULL nested input under %s", plan$plan_id)
      )
    }

    delim_struct_fn <- paste0("dyn_delim_struct_", plan_name)
    delim_struct_result <- try({
      invisible(rducks_register_scalar_udf(
        con,
        delim_struct_fn,
        rducks_dynamic_delim_struct_summary,
        returns = VARCHAR,
        null_handling = "special",
        side_effects = TRUE
      ))
      DBI::dbGetQuery(
        con,
        sprintf("SELECT %s(%s) AS x", delim_struct_fn, rducks_dynamic_delim_struct_sql())
      )$x[[1L]]
    }, silent = TRUE)

    if (rducks_expect_no_try_error(
      delim_struct_result,
      sprintf("dynamic args should preserve delimiter-bearing STRUCT names under %s", plan$plan_id)
    )) {
      expect_equal(
        delim_struct_result,
        "7|x",
        info = sprintf("dynamic delimiter-bearing STRUCT names under %s", plan$plan_id)
      )
    }

    exotic_fn <- paste0("dyn_exotic_", plan_name)
    exotic_result <- try({
      invisible(rducks_register_scalar_udf(
        con,
        exotic_fn,
        rducks_dynamic_value_string,
        returns = VARCHAR,
        null_handling = "special",
        side_effects = TRUE
      ))
      vapply(rducks_dynamic_exotic_cases, function(case) {
        DBI::dbGetQuery(
          con,
          sprintf("SELECT %s(%s) AS x", exotic_fn, case$sql)
        )$x[[1L]]
      }, character(1))
    }, silent = TRUE)

    if (rducks_expect_no_try_error(
      exotic_result,
      sprintf("dynamic args should marshal exotic scalar inputs under %s", plan$plan_id)
    )) {
      expect_equal(
        exotic_result,
        vapply(rducks_dynamic_exotic_cases, `[[`, character(1), "expected_value"),
        info = sprintf("dynamic exotic scalar values under %s", plan$plan_id)
      )
    }

    vectorized_fn <- paste0("dyn_vec_nested_", plan_name)
    vectorized_result <- try({
      invisible(rducks_register_scalar_udf(
        con,
        vectorized_fn,
        rducks_dynamic_nested_summary_vec,
        returns = VARCHAR,
        mode = "vectorized",
        null_handling = "special",
        side_effects = TRUE
      ))
      DBI::dbGetQuery(
        con,
        sprintf(
          "SELECT %s(%s) AS x FROM range(1, 4) t(i)",
          vectorized_fn,
          rducks_dynamic_nested_sql("i")
        )
      )$x
    }, silent = TRUE)

    if (rducks_expect_no_try_error(
      vectorized_result,
      sprintf("dynamic args should marshal nested vectorized inputs under %s", plan$plan_id)
    )) {
      expect_equal(
        vectorized_result,
        c(
          "1|1,2|k=1|1,3|label=v1",
          "2|2,3|k=2|2,4|label=v2",
          "3|3,4|k=3|3,5|label=v3"
        ),
        info = sprintf("dynamic nested vectorized result under %s", plan$plan_id)
      )
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
  con <- rducks_dynamic_consistency_connection()
  on.exit({
    try(rducks_release(con), silent = TRUE)
    try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE)
  }, add = TRUE)

  rducks_set_execution_plan(con, rducks_execution_plan("arrow_c", "serial"), threads = 1L, external_threads = 1L)
  invisible(rducks_register_scalar_udf(
    con,
    "dyn_arrow_c_queued_sum",
    function(...) sum(vapply(list(...), function(x) as.numeric(x)[[1L]], numeric(1))),
    returns = DOUBLE,
    null_handling = "special",
    side_effects = TRUE
  ))
  rducks_enable_inproc(con, threads = 4L, external_threads = 1L)
  n <- 4096L
  queued_result <- DBI::dbGetQuery(
    con,
    sprintf(
      "SELECT sum(dyn_arrow_c_queued_sum(i::DOUBLE, 1::DOUBLE)) AS x FROM rducks_parallel_range(%d::UBIGINT) AS t(i)",
      n
    )
  )$x[[1L]]
  expect_equal(queued_result, sum(seq_len(n)), info = "dynamic arrow_c queued path uses bound arguments")
  explain <- rducks_explain_udf(con, "dyn_arrow_c_queued_sum")
  expect_true(explain$queued_chunks >= 1, info = "dynamic arrow_c queued test forced queued chunks")
})

local({
  con <- rducks_dynamic_consistency_connection()
  on.exit({
    try(rducks_release(con), silent = TRUE)
    try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE)
  }, add = TRUE)

  invisible(rducks_register_scalar_udf(
    con,
    "declared_nested_summary",
    rducks_dynamic_nested_summary_one,
    args = rducks_dynamic_nested_type,
    returns = VARCHAR,
    null_handling = "special"
  ))
  invisible(rducks_register_scalar_udf(
    con,
    "dynamic_nested_summary",
    rducks_dynamic_nested_summary_one,
    returns = VARCHAR,
    null_handling = "special"
  ))

  sql <- rducks_dynamic_nested_sql("7")
  declared <- DBI::dbGetQuery(con, sprintf("SELECT declared_nested_summary(%s) AS x", sql))$x[[1L]]
  dynamic <- DBI::dbGetQuery(con, sprintf("SELECT dynamic_nested_summary(%s) AS x", sql))$x[[1L]]
  expect_equal(declared, "7|7,8|k=7|7,9|label=v7", info = "declared nested known output")
  expect_equal(dynamic, declared, info = "dynamic nested output matches declared nested output")
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
  cases <- rducks_dynamic_exotic_cases

  for (case_name in names(cases)) {
    case <- cases[[case_name]]
    if (!is.null(case$declared) && isFALSE(case$declared)) next
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
  invisible(rducks_register_scalar_udf(
    con,
    "dynamic_value_probe",
    rducks_dynamic_value_string,
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

    dynamic_value <- try(DBI::dbGetQuery(
      con,
      sprintf("SELECT dynamic_value_probe(%s) AS x", case$sql)
    )$x[[1L]], silent = TRUE)

    if (rducks_expect_no_try_error(
      dynamic_value,
      sprintf("dynamic args should return a known %s value", case_name)
    )) {
      expect_equal(
        dynamic_value,
        case$expected_value,
        info = sprintf("dynamic args known %s value", case_name)
      )
    }
  }
})
