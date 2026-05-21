Sys.setenv(RDUCKS_DEV_SURFACES = "true")
library(Rducks)

# Dynamic omitted-`args` is a bind-time type-resolution feature, not a loose
# conversion mode. These tests keep the matrix explicit: declared and omitted
# registrations must produce the same known R-facing values for the same DuckDB
# logical types. Cross-plan checks are concentrated on nested/internal-NULL
# values so every transport exercises the hard case without making the suite a
# slow Cartesian product.

rducks_semantic_connection <- function() {
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
  rducks_enable(con, threads = "single")
  con
}

rducks_semantic_ipc_transport <- function() {
  transports <- Rducks:::rducks_nng_runtime_transports()
  preferred <- Rducks:::rducks_nng_default_transport()
  if (preferred %in% transports) preferred else transports[[1L]]
}

rducks_semantic_cleanup <- function(con, stop_nng = FALSE) {
  try(rducks_release(con), silent = TRUE)
  if (isTRUE(stop_nng)) try(Rducks:::rducks_nng_stop_all_providers(quiet = TRUE), silent = TRUE)
  try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE)
}

rducks_semantic_register <- function(con, name, fun, declared = FALSE, args = NULL, ...) {
  if (isTRUE(declared)) {
    rducks_register_scalar_udf(con, name, fun, args = args, ...)
  } else {
    rducks_register_scalar_udf(con, name, fun, ...)
  }
}

rducks_semantic_number <- function(x) {
  if (is.na(x)) return("NA")
  format(x, trim = TRUE, scientific = FALSE, digits = 15)
}

rducks_semantic_element <- function(x, i) {
  if (is.null(x)) return(NULL)
  if (is.raw(x)) return(x[i])
  if (inherits(x, "POSIXct")) return(x[i])
  if (inherits(x, "Date")) return(x[i])
  if (is.atomic(x) || is.factor(x)) return(x[i])
  x[[i]]
}

rducks_semantic_value <- function(x) {
  if (is.null(x)) return("NULL")
  if (inherits(x, "rducks_union")) {
    return(paste0("union<", x$tag, "=", rducks_semantic_value(x$value), ">"))
  }
  if (inherits(x, c(
    "rducks_bigint", "rducks_ubigint", "rducks_hugeint", "rducks_uhugeint",
    "rducks_uuid", "rducks_interval", "rducks_decimal", "rducks_bits", "rducks_enum"
  ))) {
    return(if (anyNA(x)) "NA" else as.character(x)[[1L]])
  }
  if (inherits(x, "POSIXct")) {
    return(if (is.na(x)) "NA" else format(x, "%Y-%m-%d %H:%M:%OS6", tz = "UTC"))
  }
  if (inherits(x, "Date")) {
    return(if (is.na(x)) "NA" else format(x, "%Y-%m-%d"))
  }
  if (is.raw(x)) {
    return(paste0("raw[", paste(sprintf("%02x", as.integer(x)), collapse = " "), "]"))
  }
  if (is.logical(x)) {
    values <- ifelse(is.na(x), "NA", as.character(x))
    return(if (length(values) == 1L) values else paste0("vec[", paste(values, collapse = ","), "]"))
  }
  if (is.integer(x) || is.numeric(x)) {
    values <- vapply(x, rducks_semantic_number, character(1))
    return(if (length(values) == 1L) values else paste0("vec[", paste(values, collapse = ","), "]"))
  }
  if (is.character(x) || is.factor(x)) {
    values <- as.character(x)
    values[is.na(values)] <- "NA"
    return(if (length(values) == 1L) values else paste0("vec[", paste(values, collapse = ","), "]"))
  }
  if (is.list(x) && identical(names(x), c("keys", "values"))) {
    n <- length(x$keys)
    entries <- vapply(seq_len(n), function(i) {
      paste0(
        rducks_semantic_value(rducks_semantic_element(x$keys, i)), "=",
        rducks_semantic_value(rducks_semantic_element(x$values, i))
      )
    }, character(1))
    return(paste0("map{", paste(entries, collapse = ","), "}"))
  }
  if (is.list(x)) {
    nms <- names(x)
    if (is.null(nms)) nms <- rep("", length(x))
    fields <- vapply(seq_along(x), function(i) {
      prefix <- if (nzchar(nms[[i]])) paste0(nms[[i]], "=") else ""
      paste0(prefix, rducks_semantic_value(x[[i]]))
    }, character(1))
    return(paste0("struct{", paste(fields, collapse = ","), "}"))
  }
  paste(as.character(x), collapse = ",")
}

rducks_semantic_vector <- function(x) {
  if (is.list(x) && !inherits(x, c(
    "rducks_union", "rducks_interval", "rducks_decimal", "rducks_bits"
  ))) {
    return(vapply(x, rducks_semantic_value, character(1)))
  }
  vapply(seq_along(x), function(i) rducks_semantic_value(rducks_semantic_element(x, i)), character(1))
}

# Keep IPC worker closure capture principled and small: these helpers are the
# complete R dependency set for the semantic UDFs, so worker plans can serialize
# this private environment instead of the whole test-file environment.
rducks_semantic_helper_env <- new.env(parent = baseenv())
for (nm in c(
  "rducks_semantic_number",
  "rducks_semantic_element",
  "rducks_semantic_value",
  "rducks_semantic_vector"
)) {
  assign(nm, get(nm), envir = rducks_semantic_helper_env)
}
for (nm in ls(rducks_semantic_helper_env, all.names = TRUE)) {
  fn <- get(nm, envir = rducks_semantic_helper_env)
  environment(fn) <- rducks_semantic_helper_env
  assign(nm, fn, envir = rducks_semantic_helper_env)
  assign(nm, fn)
}

rducks_semantic_nested_null_type <- STRUCT(
  a = INTEGER,
  vals = LIST(INTEGER),
  meta = MAP(VARCHAR, VARCHAR),
  pair = ARRAY(INTEGER, 2),
  choice = UNION(code = INTEGER, label = VARCHAR),
  child = STRUCT(flag = BOOLEAN, note = VARCHAR)
)

rducks_semantic_nested_null_sql <- function(i = "1") {
  sprintf(
    paste0(
      "struct_pack(",
      "a := %1$s::INTEGER, ",
      "vals := [%1$s::INTEGER, NULL::INTEGER, (%1$s + 2)::INTEGER], ",
      "meta := map(['row','missing'], [CAST(%1$s AS VARCHAR), NULL::VARCHAR]), ",
      "pair := [NULL::INTEGER, (%1$s + 10)::INTEGER]::INTEGER[2], ",
      "choice := union_value(label := NULL::VARCHAR)::UNION(code INTEGER, label VARCHAR), ",
      "child := struct_pack(flag := ((%1$s %% 2) = 0), note := NULL::VARCHAR)",
      ")::%2$s"
    ),
    i,
    rducks_type_sql(rducks_semantic_nested_null_type)
  )
}

rducks_semantic_nested_null_expected <- function(i) {
  sprintf(
    paste0(
      "struct{a=%1$d,vals=vec[%1$d,NA,%2$d],meta=map{row=%1$d,missing=NA},",
      "pair=vec[NA,%3$d],choice=union<label=NA>,child=struct{flag=%4$s,note=NA}}"
    ),
    i, i + 2L, i + 10L, if (i %% 2L == 0L) "TRUE" else "FALSE"
  )
}

rducks_semantic_scalar_cases <- list(
  bool = list(type = BOOLEAN, sql = "TRUE::BOOLEAN", expected = "TRUE"),
  tinyint = list(type = TINYINT, sql = "-7::TINYINT", expected = "-7"),
  utinyint = list(type = UTINYINT, sql = "250::UTINYINT", expected = "250"),
  smallint = list(type = SMALLINT, sql = "-1234::SMALLINT", expected = "-1234"),
  usmallint = list(type = USMALLINT, sql = "65000::USMALLINT", expected = "65000"),
  integer = list(type = INTEGER, sql = "-123456::INTEGER", expected = "-123456"),
  uinteger = list(type = UINTEGER, sql = "42::UINTEGER", expected = "42"),
  bigint = list(type = BIGINT, sql = "9223372036854775806::BIGINT", expected = "9223372036854775806"),
  ubigint = list(type = UBIGINT, sql = "18446744073709551614::UBIGINT", expected = "18446744073709551614"),
  float = list(type = FLOAT, sql = "1.25::FLOAT", expected = "1.25"),
  double = list(type = DOUBLE, sql = "1.5::DOUBLE", expected = "1.5"),
  varchar = list(type = VARCHAR, sql = "'duck'::VARCHAR", expected = "duck"),
  blob = list(type = BLOB, sql = "'\\xDE\\xAD\\xBE\\xEF'::BLOB", expected = "raw[de ad be ef]"),
  date = list(type = DATE, sql = "DATE '2024-01-02'", expected = "2024-01-02"),
  time = list(type = TIME, sql = "TIME '12:34:56.123456'", expected = "45296.123456"),
  timestamp = list(type = TIMESTAMP, sql = "TIMESTAMP '2024-01-02 03:04:05.123456'", expected = "2024-01-02 03:04:05.123456"),
  decimal = list(type = DECIMAL(10, 2), sql = "12.34::DECIMAL(10,2)", expected = "12.34"),
  uuid = list(type = UUID, sql = "'550e8400-e29b-41d4-a716-446655440000'::UUID", expected = "550e8400-e29b-41d4-a716-446655440000"),
  hugeint = list(type = HUGEINT, sql = "170141183460469231731687303715884105726::HUGEINT", expected = "170141183460469231731687303715884105726"),
  uhugeint = list(type = UHUGEINT, sql = "340282366920938463463374607431768211454::UHUGEINT", expected = "340282366920938463463374607431768211454"),
  interval = list(type = INTERVAL, sql = "INTERVAL '2 days'", expected = "0 months 2 days 0 micros"),
  bit = list(type = BIT, sql = "'1010'::BIT", expected = "1010"),
  enum = list(type = ENUM(c("red", "blue")), sql = "'red'::ENUM('red','blue')", expected = "red"),
  enum_delimiter = list(type = ENUM(c("a|b", "semi;colon")), sql = "'semi;colon'::ENUM('a|b','semi;colon')", expected = "semi;colon"),
  list_with_null = list(type = LIST(INTEGER), sql = "[1::INTEGER, NULL::INTEGER, 3::INTEGER]", expected = "vec[1,NA,3]"),
  array_with_null = list(type = ARRAY(INTEGER, 2), sql = "[NULL::INTEGER, 5::INTEGER]::INTEGER[2]", expected = "vec[NA,5]"),
  map_with_null = list(type = MAP(VARCHAR, INTEGER), sql = "map(['a','b'], [1::INTEGER, NULL::INTEGER])", expected = "map{a=1,b=NA}"),
  struct_with_null = list(type = STRUCT(a = INTEGER, b = VARCHAR), sql = "struct_pack(a := NULL::INTEGER, b := 'x')", expected = "struct{a=NA,b=x}"),
  union_null_payload = list(type = UNION(code = INTEGER, label = VARCHAR), sql = "union_value(code := NULL::INTEGER)::UNION(code INTEGER, label VARCHAR)", expected = "union<code=NA>"),
  nested_internal_nulls = list(type = rducks_semantic_nested_null_type, sql = rducks_semantic_nested_null_sql("1"), expected = rducks_semantic_nested_null_expected(1L))
)

local({
  con <- rducks_semantic_connection()
  on.exit(rducks_semantic_cleanup(con), add = TRUE)
  rducks_set_execution_plan(con, rducks_execution_plan("arrow_r", "serial"), threads = 1L, external_threads = 1L)

  for (case_name in names(rducks_semantic_scalar_cases)) {
    case <- rducks_semantic_scalar_cases[[case_name]]
    declared_name <- paste0("sem_declared_", case_name)
    dynamic_name <- paste0("sem_dynamic_", case_name)
    invisible(rducks_register_scalar_udf(
      con,
      declared_name,
      rducks_semantic_value,
      args = case$type,
      returns = VARCHAR,
      null_handling = "special",
      side_effects = TRUE
    ))
    invisible(rducks_register_scalar_udf(
      con,
      dynamic_name,
      rducks_semantic_value,
      returns = VARCHAR,
      null_handling = "special",
      side_effects = TRUE
    ))

    declared <- DBI::dbGetQuery(con, sprintf("SELECT %s(%s) AS x", declared_name, case$sql))$x[[1L]]
    dynamic <- DBI::dbGetQuery(con, sprintf("SELECT %s(%s) AS x", dynamic_name, case$sql))$x[[1L]]
    expect_equal(declared, case$expected, info = sprintf("declared known output for %s", case_name))
    expect_equal(dynamic, case$expected, info = sprintf("dynamic known output for %s", case_name))
    expect_equal(dynamic, declared, info = sprintf("dynamic matches declared for %s", case_name))
  }
})

local({
  con <- rducks_semantic_connection()
  on.exit(rducks_semantic_cleanup(con), add = TRUE)
  rducks_set_execution_plan(con, rducks_execution_plan("arrow_r", "serial"), threads = 1L, external_threads = 1L)

  args <- list(
    INTEGER,
    DECIMAL(10, 2),
    STRUCT(flag = BOOLEAN, label = VARCHAR),
    LIST(INTEGER),
    rducks_semantic_nested_null_type
  )
  sql_args <- c(
    "7::INTEGER",
    "12.30::DECIMAL(10,2)",
    "struct_pack(flag := TRUE, label := 'ok')",
    "[1::INTEGER, NULL::INTEGER]",
    rducks_semantic_nested_null_sql("2")
  )
  expected <- paste(c(
    "7",
    "12.30",
    "struct{flag=TRUE,label=ok}",
    "vec[1,NA]",
    rducks_semantic_nested_null_expected(2L)
  ), collapse = "|")
  summarise_dots <- function(...) paste(vapply(list(...), rducks_semantic_value, character(1)), collapse = "|")

  invisible(rducks_register_scalar_udf(
    con, "sem_declared_multi", summarise_dots,
    args = args, returns = VARCHAR, null_handling = "special", side_effects = TRUE
  ))
  invisible(rducks_register_scalar_udf(
    con, "sem_dynamic_multi", summarise_dots,
    returns = VARCHAR, null_handling = "special", side_effects = TRUE
  ))

  call_sql <- paste(sql_args, collapse = ", ")
  declared <- DBI::dbGetQuery(con, sprintf("SELECT sem_declared_multi(%s) AS x", call_sql))$x[[1L]]
  dynamic <- DBI::dbGetQuery(con, sprintf("SELECT sem_dynamic_multi(%s) AS x", call_sql))$x[[1L]]
  expect_equal(declared, expected, info = "declared heterogeneous multi-argument known output")
  expect_equal(dynamic, expected, info = "dynamic heterogeneous multi-argument known output")
  expect_equal(dynamic, declared, info = "dynamic heterogeneous multi-argument call matches declared")
})

local({
  old_warn <- getOption("rducks.ipc_globals.warn_bytes")
  options(rducks.ipc_globals.warn_bytes = Inf)
  on.exit(options(rducks.ipc_globals.warn_bytes = old_warn), add = TRUE)

  plans <- list(
    arrow_r_serial = rducks_execution_plan("arrow_r", "serial"),
    arrow_r_inproc = rducks_execution_plan("arrow_r", "inproc_concurrent"),
    arrow_c_serial = rducks_execution_plan("arrow_c", "serial"),
    arrow_c_inproc = rducks_execution_plan("arrow_c", "inproc_concurrent"),
    arrow_ipc = rducks_execution_plan(
      "arrow_ipc", "multiprocess_parallel",
      ipc_workers = 1L,
      ipc_transport = rducks_semantic_ipc_transport(),
      ipc_timeout = 30,
      ipc_globals = FALSE
    )
  )
  expected <- vapply(1:3, rducks_semantic_nested_null_expected, character(1))

  for (plan_name in names(plans)) {
    plan <- plans[[plan_name]]
    con <- rducks_semantic_connection()
    tryCatch({
      rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
      declared_name <- paste0("sem_vec_declared_", plan_name)
      dynamic_name <- paste0("sem_vec_dynamic_", plan_name)
      invisible(rducks_register_scalar_udf(
        con,
        declared_name,
        rducks_semantic_vector,
        args = rducks_semantic_nested_null_type,
        returns = VARCHAR,
        mode = "vectorized",
        null_handling = "special",
        side_effects = TRUE
      ))
      invisible(rducks_register_scalar_udf(
        con,
        dynamic_name,
        rducks_semantic_vector,
        returns = VARCHAR,
        mode = "vectorized",
        null_handling = "special",
        side_effects = TRUE
      ))

      expr <- rducks_semantic_nested_null_sql("i")
      declared <- DBI::dbGetQuery(
        con,
        sprintf("SELECT %s(%s) AS x FROM range(1, 4) t(i)", declared_name, expr)
      )$x
      dynamic <- DBI::dbGetQuery(
        con,
        sprintf("SELECT %s(%s) AS x FROM range(1, 4) t(i)", dynamic_name, expr)
      )$x
      expect_equal(declared, expected, info = sprintf("declared vectorized nested internal NULLs under %s", plan$plan_id))
      expect_equal(dynamic, expected, info = sprintf("dynamic vectorized nested internal NULLs under %s", plan$plan_id))
      expect_equal(dynamic, declared, info = sprintf("dynamic vectorized nested internal NULLs match declared under %s", plan$plan_id))
    }, finally = {
      rducks_semantic_cleanup(con, stop_nng = identical(plan$marshalling, "arrow_ipc"))
    })
  }
})

local({
  con <- rducks_semantic_connection()
  on.exit(rducks_semantic_cleanup(con), add = TRUE)
  rducks_set_execution_plan(con, rducks_execution_plan("arrow_r", "serial"), threads = 1L, external_threads = 1L)

  for (declared in c(TRUE, FALSE)) {
    prefix <- if (declared) "declared" else "dynamic"
    top_name <- paste0("sem_default_top_", prefix)
    invisible(rducks_semantic_register(
      con,
      top_name,
      function(x) stop("default NULL handling should not call R for top-level NULL"),
      declared = declared,
      args = rducks_semantic_nested_null_type,
      returns = VARCHAR,
      null_handling = "default",
      exception_handling = "return_null",
      side_effects = TRUE
    ))
    top <- DBI::dbGetQuery(
      con,
      sprintf("SELECT %s(NULL::%s) AS x", top_name, rducks_type_sql(rducks_semantic_nested_null_type))
    )$x[[1L]]
    expect_true(is.na(top), info = sprintf("%s top-level NULL short-circuits before R", prefix))

    inner_name <- paste0("sem_default_inner_", prefix)
    invisible(rducks_semantic_register(
      con,
      inner_name,
      rducks_semantic_value,
      declared = declared,
      args = rducks_semantic_nested_null_type,
      returns = VARCHAR,
      null_handling = "default",
      side_effects = TRUE
    ))
    inner <- DBI::dbGetQuery(
      con,
      sprintf("SELECT %s(%s) AS x", inner_name, rducks_semantic_nested_null_sql("1"))
    )$x[[1L]]
    expect_equal(inner, rducks_semantic_nested_null_expected(1L), info = sprintf("%s default handling preserves internal NULLs", prefix))
  }
})

local({
  con <- rducks_semantic_connection()
  on.exit(rducks_semantic_cleanup(con), add = TRUE)
  rducks_set_execution_plan(con, rducks_execution_plan("arrow_r", "serial"), threads = 1L, external_threads = 1L)

  for (declared in c(TRUE, FALSE)) {
    prefix <- if (declared) "declared" else "dynamic"
    name <- paste0("sem_vec_default_", prefix)
    seen <- new.env(parent = emptyenv())
    seen$calls <- 0L
    seen$lengths <- integer()
    fun <- function(x) {
      seen$calls <- seen$calls + 1L
      seen$lengths <- c(seen$lengths, length(x))
      rducks_semantic_vector(x)
    }
    invisible(rducks_semantic_register(
      con,
      name,
      fun,
      declared = declared,
      args = rducks_semantic_nested_null_type,
      returns = VARCHAR,
      mode = "vectorized",
      null_handling = "default",
      side_effects = TRUE
    ))
    rows_sql <- sprintf(
      paste0(
        "SELECT %s AS x ",
        "UNION ALL SELECT NULL::%s AS x ",
        "UNION ALL SELECT %s AS x"
      ),
      rducks_semantic_nested_null_sql("1"),
      rducks_type_sql(rducks_semantic_nested_null_type),
      rducks_semantic_nested_null_sql("3")
    )
    result <- DBI::dbGetQuery(con, sprintf("SELECT %s(x) AS x FROM (%s) t", name, rows_sql))$x
    expect_equal(
      result,
      c(rducks_semantic_nested_null_expected(1L), NA_character_, rducks_semantic_nested_null_expected(3L)),
      info = sprintf("%s vectorized default scatters top-level NULL rows", prefix)
    )
    expect_true(seen$calls >= 1L, info = sprintf("%s vectorized default evaluates at least one non-NULL chunk", prefix))
    expect_equal(sum(seen$lengths), 2L, info = sprintf("%s vectorized default passes only non-NULL rows", prefix))
    expect_true(all(seen$lengths > 0L), info = sprintf("%s vectorized default never calls R with an empty chunk", prefix))
  }
})

local({
  con <- rducks_semantic_connection()
  on.exit(rducks_semantic_cleanup(con), add = TRUE)
  rducks_set_execution_plan(con, rducks_execution_plan("arrow_r", "serial"), threads = 1L, external_threads = 1L)

  cases <- list(
    integer = list(type = INTEGER, sql = "NULL::INTEGER", expected = "NA"),
    nested = list(
      type = rducks_semantic_nested_null_type,
      sql = paste0("NULL::", rducks_type_sql(rducks_semantic_nested_null_type)),
      expected = "NULL"
    )
  )

  for (case_name in names(cases)) {
    case <- cases[[case_name]]
    declared_name <- paste0("sem_special_null_declared_", case_name)
    dynamic_name <- paste0("sem_special_null_dynamic_", case_name)
    invisible(rducks_register_scalar_udf(
      con,
      declared_name,
      rducks_semantic_value,
      args = case$type,
      returns = VARCHAR,
      null_handling = "special",
      side_effects = TRUE
    ))
    invisible(rducks_register_scalar_udf(
      con,
      dynamic_name,
      rducks_semantic_value,
      returns = VARCHAR,
      null_handling = "special",
      side_effects = TRUE
    ))
    declared <- DBI::dbGetQuery(con, sprintf("SELECT %s(%s) AS x", declared_name, case$sql))$x[[1L]]
    dynamic <- DBI::dbGetQuery(con, sprintf("SELECT %s(%s) AS x", dynamic_name, case$sql))$x[[1L]]
    expect_equal(declared, case$expected, info = sprintf("declared top-level special NULL for %s", case_name))
    expect_equal(dynamic, case$expected, info = sprintf("dynamic top-level special NULL for %s", case_name))
    expect_equal(dynamic, declared, info = sprintf("dynamic top-level special NULL matches declared for %s", case_name))
  }
})

local({
  con <- rducks_semantic_connection()
  on.exit(rducks_semantic_cleanup(con), add = TRUE)
  invisible(rducks_register_scalar_udf(
    con,
    "sem_dynamic_untyped_null",
    function(x) "called",
    returns = VARCHAR,
    null_handling = "special"
  ))
  err <- try(DBI::dbGetQuery(con, "SELECT sem_dynamic_untyped_null(NULL) AS x"), silent = TRUE)
  expect_true(inherits(err, "try-error"), info = "dynamic untyped NULL has no concrete bind-time argument type")
  expect_true(
    grepl("cast NULL|declare args|concrete DuckDB types", conditionMessage(attr(err, "condition"))),
    info = "dynamic untyped NULL error explains how to make the type concrete"
  )

  param_err <- try(
    DBI::dbGetQuery(con, "SELECT sem_dynamic_untyped_null(?) AS x", params = list(1L)),
    silent = TRUE
  )
  expect_true(inherits(param_err, "try-error"), info = "dynamic parameter marker has no bind-time argument type")
  expect_true(
    grepl("cast NULL|parameter markers|declare args|concrete DuckDB types", conditionMessage(attr(param_err, "condition"))),
    info = "dynamic parameter marker error explains how to make the type concrete"
  )
})
