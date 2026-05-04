#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(Rducks)
  library(DBI)
  library(duckdb)
  library(future)
})

main <- function() {
limit <- as.integer(Sys.getenv("RDUCKS_MATRIX_MAX", "0"))
if (is.na(limit)) limit <- 0L
include_ipc <- tolower(Sys.getenv("RDUCKS_MATRIX_INCLUDE_IPC", "false")) %in% c("1", "true", "yes")
future_workers <- suppressWarnings(as.integer(Sys.getenv("RDUCKS_MATRIX_FUTURE_WORKERS", "1")))
if (length(future_workers) != 1L || is.na(future_workers) || future_workers < 1L) future_workers <- 1L
old_future_plan <- future::plan()
on.exit(future::plan(old_future_plan), add = TRUE)
if (include_ipc) {
  future::plan(future::multisession, workers = future_workers)
  if (!isTRUE(Rducks:::rducks_arrow_ipc_mapping_supported(INTEGER))) {
    stop("Arrow IPC matrix smoke check failed: INTEGER mapping is not supported", call. = FALSE)
  }
  if (!identical(Rducks:::rducks_arrow_ipc_unsupported_types(INTEGER), character())) {
    stop("Arrow IPC matrix smoke check failed: INTEGER reported as unsupported", call. = FALSE)
  }
}

con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
rducks_enable(con, threads = "single")

case_counter <- 0L
run_counter <- 0L

next_name <- function(prefix) {
  case_counter <<- case_counter + 1L
  sprintf("rducks_ci_%s_%04d", prefix, case_counter)
}

maybe_stop_for_limit <- function() {
  run_counter <<- run_counter + 1L
  if (limit > 0L && run_counter > limit) {
    stop(structure(
      list(message = paste0("RDUCKS_MATRIX_MAX reached after ", limit, " generated cases")),
      class = c("rducks_matrix_limit", "condition")
    ))
  }
}

sql_ok <- function(sql, label) {
  res <- tryCatch(
    DBI::dbGetQuery(con, sql),
    error = function(e) {
      stop(
        "generated marshalling case errored: ", label,
        "\nSQL: ", sql,
        "\n", conditionMessage(e),
        call. = FALSE
      )
    }
  )
  if (!NROW(res) || !isTRUE(res$ok[[1L]])) {
    stop("generated marshalling case failed: ", label, "\nSQL: ", sql, call. = FALSE)
  }
  invisible(TRUE)
}

sql_compare_expr <- function(got, expected) {
  sprintf("(%s) IS NOT DISTINCT FROM (%s) AND typeof(%s) = typeof(%s)", got, expected, got, expected)
}

run_identity <- function(case) {
  maybe_stop_for_limit()
  name <- next_name("id")
  invisible(rducks_register(con, name, function(x) x, case$type, case$type))
  got <- sprintf("%s(%s)", name, case$sql1)
  sql_ok(sprintf("SELECT %s AS ok", sql_compare_expr(got, case$sql1)), paste0("identity ", case$name))
}

run_return <- function(case) {
  maybe_stop_for_limit()
  name <- next_name("ret")
  value <- case$r1
  invisible(rducks_register(con, name, function() value, character(), case$type))
  got <- sprintf("%s()", name)
  sql_ok(sprintf("SELECT %s AS ok", sql_compare_expr(got, case$sql1)), paste0("return ", case$name))
}

assert_vectorized_marshalling_counter <- function(name, marshalling, label) {
  info <- rducks_explain_udf(con, name)
  if (!identical(info$native_marshalling[[1L]], marshalling)) {
    stop(
      "generated marshalling case used wrong native marshalling: ", label,
      " expected ", marshalling, " got ", info$native_marshalling[[1L]],
      call. = FALSE
    )
  }
  expected <- paste0(marshalling, "_chunks")
  others <- setdiff(c("arrow_r_chunks", "arrow_c_chunks", "arrow_ipc_chunks"), expected)
  bad_other <- vapply(others, function(field) info[[field]][[1L]] != 0, logical(1))
  if (info[[expected]][[1L]] < 1 || any(bad_other)) {
    stop(
      "generated marshalling case violated no-fallback counters: ", label,
      " ", expected, "=", info[[expected]][[1L]],
      " others=", paste(paste0(others, "=", vapply(others, function(field) info[[field]][[1L]], numeric(1))), collapse = ","),
      call. = FALSE
    )
  }
  invisible(TRUE)
}

run_vectorized_row_conformance_one_plan <- function(marshalling, type, sql1, sql2, label, include_null = TRUE) {
  plan <- if (identical(marshalling, "arrow_ipc")) {
    rducks_execution_plan("arrow_ipc", "multiprocess_parallel", future_timeout = 60)
  } else {
    rducks_execution_plan(marshalling, "serial")
  }
  rducks_set_execution_plan(con, plan)
  type_sql <- rducks_type_sql(type)
  values_sql <- if (include_null) {
    sprintf("(%s), (NULL::%s), (%s)", sql1, type_sql, sql2)
  } else {
    sprintf("(%s), (%s)", sql1, sql2)
  }

  maybe_stop_for_limit()
  row_name <- next_name(paste0(marshalling, "_row"))
  vec_name <- next_name(paste0(marshalling, "_vec"))
  invisible(rducks_register(con, row_name, function(x) x, type, type, side_effects = TRUE))
  invisible(rducks_register(con, vec_name, function(x) x, type, type, mode = "vectorized", side_effects = TRUE))
  row_expr <- sprintf("%s(x)", row_name)
  vec_expr <- sprintf("%s(x)", vec_name)
  default_label <- paste0(marshalling, " vectorized/default vs scalar ", label)
  sql_ok(
    sprintf("WITH data(x) AS (VALUES %s) SELECT bool_and(%s) AS ok FROM data", values_sql, sql_compare_expr(vec_expr, row_expr)),
    default_label
  )
  assert_vectorized_marshalling_counter(vec_name, marshalling, default_label)

  if (include_null) {
    maybe_stop_for_limit()
    row_special_name <- next_name(paste0(marshalling, "_row_special"))
    vec_special_name <- next_name(paste0(marshalling, "_vec_special"))
    invisible(rducks_register(con, row_special_name, function(x) x, type, type,
                              null_handling = "special", side_effects = TRUE))
    invisible(rducks_register(con, vec_special_name, function(x) x, type, type,
                              mode = "vectorized", null_handling = "special", side_effects = TRUE))
    row_special_expr <- sprintf("%s(x)", row_special_name)
    vec_special_expr <- sprintf("%s(x)", vec_special_name)
    special_label <- paste0(marshalling, " vectorized/special vs scalar ", label)
    sql_ok(
      sprintf("WITH data(x) AS (VALUES %s) SELECT bool_and(%s) AS ok FROM data", values_sql, sql_compare_expr(vec_special_expr, row_special_expr)),
      special_label
    )
    assert_vectorized_marshalling_counter(vec_special_name, marshalling, special_label)
  }
}

run_vectorized_row_conformance <- function(type, sql1, sql2, label, include_null = TRUE) {
  include_ipc_for_type <- isTRUE(include_ipc) &&
    Rducks:::rducks_arrow_ipc_mapping_supported(type)
  marshallers <- c("arrow_r", "arrow_c", if (include_ipc_for_type) "arrow_ipc")
  for (marshalling in marshallers) {
    run_vectorized_row_conformance_one_plan(marshalling, type, sql1, sql2, label, include_null = include_null)
  }
  rducks_set_execution_plan(con, rducks_execution_plan("arrow_r", "serial"))
}

sequence_r_value <- function(case) {
  if (case$name %in% c("blob", "bit") || rducks_type_kind(case$type) %in% c("decimal", "enum", "union")) {
    list(case$r1, case$r2)
  } else if (inherits(case$r1, "rducks_interval")) {
    c(case$r1, case$r2)
  } else {
    c(case$r1, case$r2)
  }
}

run_composite_identity <- function(case, shape) {
  maybe_stop_for_limit()
  type_sql <- rducks_type_sql(case$type)
  spec <- switch(shape,
    list = list(
      type = LIST(case$type),
      sql = sprintf("[%s, %s]::%s[]", case$sql1, case$sql2, type_sql),
      r = sequence_r_value(case)
    ),
    array = list(
      type = ARRAY(case$type, 2),
      sql = sprintf("[%s, %s]::%s[2]", case$sql1, case$sql2, type_sql),
      r = sequence_r_value(case)
    ),
    struct = list(
      type = STRUCT(a = case$type, b = case$type),
      sql = sprintf("{'a': %s, 'b': %s}::STRUCT(a %s, b %s)", case$sql1, case$sql2, type_sql, type_sql),
      r = list(a = case$r1, b = case$r2)
    ),
    map = list(
      type = MAP(VARCHAR, case$type),
      sql = sprintf("map(['a', 'b'], [%s, %s]::%s[])", case$sql1, case$sql2, type_sql),
      r = list(keys = c("a", "b"), values = sequence_r_value(case))
    ),
    stop("unknown shape", call. = FALSE)
  )
  name <- next_name(shape)
  invisible(rducks_register(con, name, function(x) x, spec$type, spec$type))
  got <- sprintf("%s(%s)", name, spec$sql)
  sql_ok(sprintf("SELECT %s AS ok", sql_compare_expr(got, spec$sql)), paste(shape, case$name))
  run_vectorized_row_conformance(spec$type, spec$sql, spec$sql, paste(shape, case$name), include_null = !identical(case$name, "union"))

  maybe_stop_for_limit()
  ret_name <- next_name(paste0("ret_", shape))
  value <- spec$r
  invisible(rducks_register(con, ret_name, function() value, character(), spec$type))
  got_ret <- sprintf("%s()", ret_name)
  sql_ok(sprintf("SELECT %s AS ok", sql_compare_expr(got_ret, spec$sql)), paste("return", shape, case$name))
}

scalar_cases <- list(
  list(name = "bool", type = BOOLEAN, sql1 = "TRUE", sql2 = "FALSE", r1 = TRUE, r2 = FALSE),
  list(name = "i8", type = TINYINT, sql1 = "7::TINYINT", sql2 = "-8::TINYINT", r1 = 7L, r2 = -8L),
  list(name = "u8", type = UTINYINT, sql1 = "7::UTINYINT", sql2 = "8::UTINYINT", r1 = 7L, r2 = 8L),
  list(name = "i16", type = SMALLINT, sql1 = "32000::SMALLINT", sql2 = "-123::SMALLINT", r1 = 32000L, r2 = -123L),
  list(name = "u16", type = USMALLINT, sql1 = "65000::USMALLINT", sql2 = "123::USMALLINT", r1 = 65000L, r2 = 123L),
  list(name = "i32", type = INTEGER, sql1 = "42::INTEGER", sql2 = "-42::INTEGER", r1 = 42L, r2 = -42L),
  list(name = "u32", type = UINTEGER, sql1 = "42::UINTEGER", sql2 = "4000000000::UINTEGER", r1 = 42, r2 = 4000000000),
  list(name = "i64", type = BIGINT, sql1 = "9223372036854775806::BIGINT", sql2 = "-9223372036854775807::BIGINT", r1 = rducks_bigint("9223372036854775806"), r2 = rducks_bigint("-9223372036854775807")),
  list(name = "u64", type = UBIGINT, sql1 = "18446744073709551614::UBIGINT", sql2 = "42::UBIGINT", r1 = rducks_ubigint("18446744073709551614"), r2 = rducks_ubigint("42")),
  list(name = "f32", type = FLOAT, sql1 = "1.5::FLOAT", sql2 = "-2.25::FLOAT", r1 = 1.5, r2 = -2.25),
  list(name = "f64", type = DOUBLE, sql1 = "2.25::DOUBLE", sql2 = "-3.5::DOUBLE", r1 = 2.25, r2 = -3.5),
  list(name = "varchar", type = VARCHAR, sql1 = "'duck'::VARCHAR", sql2 = "'db'::VARCHAR", r1 = "duck", r2 = "db"),
  list(name = "blob", type = BLOB, sql1 = "from_hex('00AA')", sql2 = "from_hex('FF')", r1 = as.raw(c(0x00, 0xaa)), r2 = as.raw(0xff)),
  list(name = "date", type = DATE, sql1 = "DATE '2020-01-02'", sql2 = "DATE '1999-12-31'", r1 = as.Date("2020-01-02"), r2 = as.Date("1999-12-31")),
  list(name = "time", type = TIME, sql1 = "TIME '01:02:03.123457'", sql2 = "TIME '23:59:58.000005'", r1 = rducks_as_time("01:02:03.123457"), r2 = rducks_as_time("23:59:58.000005")),
  list(name = "timestamp", type = TIMESTAMP, sql1 = "TIMESTAMP '2020-01-02 03:04:05.123457'", sql2 = "TIMESTAMP '1999-12-31 23:59:58.000005'", r1 = rducks_as_timestamp("2020-01-02 03:04:05.123457"), r2 = rducks_as_timestamp("1999-12-31 23:59:58.000005")),
  list(name = "hugeint", type = HUGEINT, sql1 = "170141183460469231731687303715884105726::HUGEINT", sql2 = "-170141183460469231731687303715884105727::HUGEINT", r1 = rducks_hugeint("170141183460469231731687303715884105726"), r2 = rducks_hugeint("-170141183460469231731687303715884105727")),
  list(name = "uhugeint", type = UHUGEINT, sql1 = "340282366920938463463374607431768211454::UHUGEINT", sql2 = "42::UHUGEINT", r1 = rducks_uhugeint("340282366920938463463374607431768211454"), r2 = rducks_uhugeint("42")),
  list(name = "uuid", type = UUID, sql1 = "'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::UUID", sql2 = "'00000000-0000-0000-0000-000000000001'::UUID", r1 = rducks_uuid("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"), r2 = rducks_uuid("00000000-0000-0000-0000-000000000001")),
  list(name = "interval", type = INTERVAL, sql1 = "INTERVAL '1 month 2 days 3 microseconds'", sql2 = "INTERVAL '4 days 5 microseconds'", r1 = rducks_interval(1L, 2L, "3"), r2 = rducks_interval(0L, 4L, "5")),
  list(name = "bit", type = BIT, sql1 = "'1010'::BIT", sql2 = "'0101'::BIT", r1 = rducks_bits("1010"), r2 = rducks_bits("0101")),
  list(name = "decimal", type = DECIMAL(10, 2), sql1 = "12.34::DECIMAL(10,2)", sql2 = "-5.50::DECIMAL(10,2)", r1 = rducks_decimal("12.34", 10, 2), r2 = rducks_decimal("-5.50", 10, 2)),
  list(name = "enum", type = ENUM(c("red", "blue")), sql1 = "'red'::ENUM('red','blue')", sql2 = "'blue'::ENUM('red','blue')", r1 = rducks_enum("red", c("red", "blue")), r2 = rducks_enum("blue", c("red", "blue"))),
  list(name = "union", type = UNION(code = INTEGER, label = VARCHAR), sql1 = "union_value(code := 42)::UNION(code INTEGER, label VARCHAR)", sql2 = "union_value(label := 'duck')::UNION(code INTEGER, label VARCHAR)", r1 = rducks_union("code", 42L), r2 = rducks_union("label", "duck"))
)

tryCatch({
  for (case in scalar_cases) {
    run_identity(case)
    run_return(case)
    run_vectorized_row_conformance(case$type, case$sql1, case$sql2, case$name, include_null = !identical(case$name, "union"))
  }

  for (case in scalar_cases) {
    for (shape in c("list", "array", "struct")) {
      run_composite_identity(case, shape)
    }
    if (!identical(case$name, "union")) {
      run_composite_identity(case, "map")
    }
  }

  message("generated marshalling matrix completed: ", run_counter, " cases")
}, rducks_matrix_limit = function(e) {
  message(conditionMessage(e))
})
}

main()
