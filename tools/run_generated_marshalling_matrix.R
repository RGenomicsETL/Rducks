#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(Rducks)
  library(DBI)
  library(duckdb)
})

main <- function() {
  limit <- as.integer(Sys.getenv("RDUCKS_MATRIX_MAX", "0"))
  if (is.na(limit)) limit <- 0L

  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  on.exit(rducks_release(con), add = TRUE)
  rducks_set_execution_plan(
    con,
    Rducks:::rducks_execution_plan_internal("direct", "serial"),
    threads = 1L,
    external_threads = 1L
  )

  case_counter <- 0L
  run_counter <- 0L

  maybe_stop_for_limit <- function() {
    run_counter <<- run_counter + 1L
    if (limit > 0L && run_counter > limit) {
      stop(structure(
        list(message = paste0("RDUCKS_MATRIX_MAX reached after ", limit, " generated cases")),
        class = c("rducks_matrix_limit", "condition")
      ))
    }
  }

  next_name <- function(prefix) {
    case_counter <<- case_counter + 1L
    sprintf("rducks_ci_%s_%04d", prefix, case_counter)
  }

  sql_ok <- function(sql, label) {
    res <- tryCatch(
      DBI::dbGetQuery(con, sql),
      error = function(e) {
        stop(
          "generated direct marshalling case errored: ", label,
          "\nSQL: ", sql,
          "\n", conditionMessage(e),
          call. = FALSE
        )
      }
    )
    if (!NROW(res) || !isTRUE(res$ok[[1L]])) {
      stop("generated direct marshalling case failed: ", label, "\nSQL: ", sql, call. = FALSE)
    }
    invisible(TRUE)
  }

  sql_compare_expr <- function(got, expected) {
    sprintf("(%s) IS NOT DISTINCT FROM (%s) AND typeof(%s) = typeof(%s)", got, expected, got, expected)
  }

  assert_direct_counter <- function(name, label) {
    info <- rducks_explain_udf(con, name)
    if (!identical(info$native_marshalling[[1L]], "direct")) {
      stop(
        "generated marshalling case used wrong native marshalling: ", label,
        " expected direct got ", info$native_marshalling[[1L]],
        call. = FALSE
      )
    }
    if (info$direct_chunks[[1L]] < 1) {
      stop("generated marshalling case did not increment direct_chunks: ", label, call. = FALSE)
    }
    if ("wire_chunks" %in% names(info) && info$wire_chunks[[1L]] != 0) {
      stop("generated direct marshalling case unexpectedly used wire chunks: ", label, call. = FALSE)
    }
    invisible(TRUE)
  }

  run_identity <- function(case) {
    maybe_stop_for_limit()
    name <- next_name("direct_id")
    invisible(rducks_register_scalar_udf(con, name, function(x) x, case$type, case$type, side_effects = TRUE))
    got <- sprintf("%s(%s)", name, case$sql1)
    sql_ok(sprintf("SELECT %s AS ok", sql_compare_expr(got, case$sql1)), paste0("identity ", case$name))
    assert_direct_counter(name, paste0("identity ", case$name))
  }

  run_return <- function(case) {
    maybe_stop_for_limit()
    name <- next_name("direct_ret")
    value <- case$r1
    invisible(rducks_register_scalar_udf(con, name, function() value, character(), case$type, side_effects = TRUE))
    got <- sprintf("%s()", name)
    sql_ok(sprintf("SELECT %s AS ok", sql_compare_expr(got, case$sql1)), paste0("return ", case$name))
    assert_direct_counter(name, paste0("return ", case$name))
  }

  run_vectorized <- function(case) {
    maybe_stop_for_limit()
    name <- next_name("direct_vec")
    invisible(rducks_register_scalar_udf(
      con, name, function(x) x, case$type, case$type,
      mode = "vectorized", side_effects = TRUE
    ))
    type_sql <- rducks_type_sql(case$type)
    values_sql <- sprintf("(%s), (NULL::%s), (%s)", case$sql1, type_sql, case$sql2)
    got <- sprintf("%s(x)", name)
    sql_ok(
      sprintf("WITH data(x) AS (VALUES %s) SELECT bool_and(%s) AS ok FROM data", values_sql, sql_compare_expr(got, "x")),
      paste0("vectorized ", case$name)
    )
    assert_direct_counter(name, paste0("vectorized ", case$name))
  }

  run_quack_roundtrip <- function(case) {
    maybe_stop_for_limit()
    values <- case$q %||% list(c(case$r1, NA, case$r2))[[1L]]
    payload <- Rducks:::rducks_wire_encode_values(list(case$type), list(values), length(values))
    decoded <- Rducks:::rducks_wire_decode_values(list(case$type), payload)
    if (!identical(decoded$rows, length(values))) {
      stop("generated Quack codec case decoded wrong row count: ", case$name, call. = FALSE)
    }
    if (!identical(decoded$values[[1L]], values)) {
      stop("generated Quack codec case decoded wrong values: ", case$name, call. = FALSE)
    }
    invisible(TRUE)
  }

  `%||%` <- function(x, y) if (is.null(x)) y else x

  scalar_cases <- list(
    list(name = "bool", type = BOOLEAN, sql1 = "TRUE", sql2 = "FALSE", r1 = TRUE, r2 = FALSE,
         q = c(TRUE, NA, FALSE)),
    list(name = "i32", type = INTEGER, sql1 = "42::INTEGER", sql2 = "-42::INTEGER", r1 = 42L, r2 = -42L,
         q = c(42L, NA_integer_, -42L)),
    list(name = "f64", type = DOUBLE, sql1 = "2.25::DOUBLE", sql2 = "-3.5::DOUBLE", r1 = 2.25, r2 = -3.5,
         q = c(2.25, NA_real_, -3.5)),
    list(name = "varchar", type = VARCHAR, sql1 = "'duck'::VARCHAR", sql2 = "'db'::VARCHAR", r1 = "duck", r2 = "db",
         q = c("duck", NA_character_, "db"))
  )

  tryCatch({
    for (case in scalar_cases) {
      run_identity(case)
      run_return(case)
      run_vectorized(case)
      run_quack_roundtrip(case)
    }
    message("generated direct/quack marshalling matrix completed: ", run_counter, " cases")
  }, rducks_matrix_limit = function(e) {
    message(conditionMessage(e))
  })
}

main()
