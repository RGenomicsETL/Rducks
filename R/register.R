.rducks_compiled_registry <- new.env(parent = emptyenv())
.rducks_compiled_registry$next_id <- 0L

rducks_keep_compiled_wrapper <- function(compiled) {
  .rducks_compiled_registry$next_id <- .rducks_compiled_registry$next_id + 1L
  id <- paste0("wrapper_", .rducks_compiled_registry$next_id)
  .rducks_compiled_registry[[id]] <- compiled
  id
}

rducks_warn_type_mapping <- function(spec) {
  mapping <- rducks_argument_type_mapping(unique(c(spec$args, spec$returns)))
  numeric_integer <- mapping$rducks_type[mapping$uses_r_double_for_integer]
  if (length(numeric_integer)) {
    warning(
      "Rducks maps ", paste(numeric_integer, collapse = ", "),
      " through R numeric (double); i64/u64 values beyond 2^53 cannot be represented exactly",
      call. = FALSE
    )
  }
  float_double <- mapping$rducks_type[mapping$uses_r_double_for_float]
  if (length(float_double)) {
    warning(
      "Rducks maps ", paste(float_double, collapse = ", "),
      " through R numeric (double) on the R side",
      call. = FALSE
    )
  }
  invisible(NULL)
}

#' Register an R UDF in DuckDB
#'
#' Registers a scalar R function as a DuckDB SQL function using the loaded Rducks
#' extension and an Rtinycc-generated shape-specific C wrapper. The current
#' implemented path is direct main-R-thread callback execution and requires
#' single-thread DuckDB execution.
#'
#' @param con A `duckdb_connection`.
#' @param name SQL function name.
#' @param fun R function.
#' @param args Character vector of Rducks scalar type tokens.
#' @param returns Scalar return type token.
#' @param mode Registration mode. Currently only `"compiled"` is implemented.
#' @param compile Kept for API compatibility; must be `TRUE`.
#' @param null_handling Either `"default"` for NULL-in/NULL-out without calling
#'   the R function, or `"special"` to call the R function with NA-like R
#'   values for NULL inputs.
#' @param exception_handling Either `"rethrow"` to report R errors to DuckDB, or
#'   `"return_null"` to turn callback errors into SQL NULL values.
#' @param side_effects Logical scalar. Use `TRUE` for callbacks with randomness,
#'   counters, I/O, mutation, or other side effects so DuckDB does not treat the
#'   function as pure.
#' @return Object of class `rducks_registration`.
#' @export
rducks_register <- function(con, name, fun, args, returns,
                            mode = c("compiled"),
                            compile = TRUE,
                            null_handling = c("default", "special"),
                            exception_handling = c("rethrow", "return_null"),
                            side_effects = FALSE) {
  mode <- match.arg(mode)
  null_handling <- match.arg(null_handling)
  exception_handling <- match.arg(exception_handling)
  if (!is.logical(side_effects) || length(side_effects) != 1L || is.na(side_effects)) {
    stop("side_effects must be TRUE or FALSE", call. = FALSE)
  }
  if (!isTRUE(compile)) {
    stop("Rducks currently requires compile = TRUE", call. = FALSE)
  }
  if (!inherits(con, "duckdb_connection")) {
    stop("con must be a duckdb_connection", call. = FALSE)
  }
  spec <- rducks_udf_spec(name, fun, args, returns, mode = mode)
  rducks_warn_type_mapping(spec)
  rducks_assert_single_thread(con)
  compiled <- rducks_compile_scalar_wrapper(spec)

  callback <- rducks_callback(fun)
  ok <- FALSE
  on.exit({
    if (!ok) rducks_callback_close(callback)
  }, add = TRUE)

  fun_ptr <- .Call(RDUCKS_callback_fun_addr, callback)
  wrapper_ptr <- .Call(RDUCKS_extptr_addr, compiled$pointer)
  sql <- sprintf(
    "SELECT rducks_register_scalar(%s, %s::UBIGINT, %s::UBIGINT, %s, %s, %s, %s, %s) AS ok",
    rducks_sql_string(name),
    as.character(fun_ptr),
    as.character(wrapper_ptr),
    rducks_sql_string(paste(spec$args, collapse = ",")),
    rducks_sql_string(spec$returns),
    rducks_sql_string(null_handling),
    rducks_sql_string(exception_handling),
    if (isTRUE(side_effects)) "TRUE" else "FALSE"
  )
  res <- DBI::dbGetQuery(con, sql)
  if (!NROW(res) || !isTRUE(res$ok[[1]])) {
    stop("native Rducks registration failed for SQL function: ", name, call. = FALSE)
  }
  ok <- TRUE
  registry_id <- rducks_keep_compiled_wrapper(compiled)

  structure(
    list(
      connection = con,
      spec = spec,
      callback = callback,
      compiled = compiled,
      compiled_registry_id = registry_id,
      null_handling = null_handling,
      exception_handling = exception_handling,
      side_effects = side_effects,
      registered = TRUE
    ),
    class = "rducks_registration"
  )
}

#' @export
print.rducks_registration <- function(x, ...) {
  cat("<rducks_registration>\n")
  cat("  registered: ", if (isTRUE(x$registered)) "yes" else "no", "\n", sep = "")
  print(x$spec)
  invisible(x)
}

#' Close an Rducks registration
#'
#' This releases the R-side callback token. The current native extension keeps
#' its own preserved reference for the registered SQL function until DuckDB
#' releases the function metadata.
#'
#' @param registration A [rducks_register()] result.
#' @return `NULL`, invisibly.
#' @export
rducks_unregister <- function(registration) {
  if (!inherits(registration, "rducks_registration")) {
    stop("registration must be a rducks_registration", call. = FALSE)
  }
  rducks_callback_close(registration$callback)
  invisible(NULL)
}
