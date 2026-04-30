rducks_warn_type_mapping <- function(spec) {
  types <- c(spec$arg_types %||% rducks_as_type_list(spec$args), list(spec$return_type %||% rducks_as_type(spec$returns)))
  mapping <- rducks_argument_type_mapping(types)
  numeric_integer <- mapping$rducks_type[mapping$uses_r_double_for_integer]
  if (length(numeric_integer)) {
    warning(
      "Rducks maps ", paste(numeric_integer, collapse = ", "),
      " through R numeric (double) on the R side",
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

rducks_type_row_marshalling_supported <- function(type) {
  if (!inherits(type, "rducks_type")) {
    type <- rducks_type_object(type)
  }
  kind <- rducks_type_kind(type)
  if (identical(kind, "scalar")) {
    return(rducks_type_token(type) %in% rducks_all_scalar_type_names())
  }
  if (kind %in% c("decimal", "enum")) {
    return(TRUE)
  }
  if (kind %in% c("list", "array", "struct", "map", "union")) {
    return(all(vapply(rducks_type_children(type), rducks_type_row_marshalling_supported, logical(1))))
  }
  FALSE
}

rducks_assert_row_marshalling_supported <- function(spec) {
  types <- c(spec$arg_types %||% rducks_as_type_list(spec$args), list(spec$return_type %||% rducks_as_type(spec$returns)))
  unsupported <- vapply(types, function(type) {
    if (rducks_type_row_marshalling_supported(type)) "" else rducks_type_duckdb_sql(type)
  }, character(1))
  unsupported <- unsupported[nzchar(unsupported)]
  if (length(unsupported)) {
    stop(
      "row-mode native marshalling is not implemented yet for: ",
      paste(unique(unsupported), collapse = ", "),
      call. = FALSE
    )
  }
  invisible(NULL)
}

#' Register an R UDF in DuckDB
#'
#' Registers a scalar R function as a DuckDB SQL function using the loaded Rducks
#' extension. The current implemented path is direct main-R-thread callback
#' execution and requires single-thread DuckDB execution.
#'
#' @param con A `duckdb_connection`.
#' @param name SQL function name.
#' @param fun R function.
#' @param args Argument type specification. Use exported DuckDB-style type
#'   objects such as `INTEGER`, `DOUBLE`, `INTEGER[]`, `INTEGER[3]`,
#'   `STRUCT(a = INTEGER)`, or `MAP(VARCHAR, INTEGER)`.
#' @param returns Return type specification.
#' @param mode Registration mode. `"row"` is implemented now and calls the R
#'   function once per row through the native Rducks DuckDB extension.
#' @param null_handling Either `"default"` for NULL-in/NULL-out without calling
#'   the R function, or `"special"` to call the R function with NA-like R
#'   values for NULL inputs.
#' @param exception_handling Either `"rethrow"` to report R errors to DuckDB, or
#'   `"return_null"` to turn callback errors into SQL NULL values.
#' @param side_effects Logical scalar. Use `TRUE` for callbacks with randomness,
#'   counters, I/O, mutation, or other side effects so DuckDB does not treat the
#'   function as pure.
#' @return Object of class `rducks_registration`. Keep this object if you want
#'   to soft-unregister the UDF later with [rducks_unregister()].
#' @export
rducks_register <- function(con, name, fun, args, returns,
                            mode = "row",
                            null_handling = c("default", "special"),
                            exception_handling = c("rethrow", "return_null"),
                            side_effects = FALSE) {
  mode <- rducks_match_mode(mode)
  null_handling <- match.arg(null_handling)
  exception_handling <- match.arg(exception_handling)
  if (!is.logical(side_effects) || length(side_effects) != 1L || is.na(side_effects)) {
    stop("side_effects must be TRUE or FALSE", call. = FALSE)
  }
  if (!inherits(con, "duckdb_connection")) {
    stop("con must be a duckdb_connection", call. = FALSE)
  }
  spec <- rducks_udf_spec(name, fun, args, returns, mode = mode)
  rducks_assert_row_marshalling_supported(spec)
  rducks_warn_type_mapping(spec)
  rducks_assert_single_thread(con)
  callback <- rducks_callback(fun)
  ok <- FALSE
  on.exit({
    if (!ok) rducks_callback_close(callback)
  }, add = TRUE)

  fun_ptr <- .Call(RDUCKS_callback_fun_addr, callback)
  sql <- sprintf(
    "SELECT rducks_register_scalar(%s, %s::UBIGINT, %s, %s, %s, %s, %s) AS ok",
    rducks_sql_string(name),
    as.character(fun_ptr),
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
  structure(
    list(
      connection = con,
      spec = spec,
      callback = callback,
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

#' Soft-unregister an Rducks registration
#'
#' DuckDB currently registers extension scalar functions as internal catalog
#' entries, so SQL `DROP FUNCTION` cannot remove them. `rducks_unregister()`
#' replaces the matching overload with an inactive stub and releases Rducks'
#' R-side callback token. Future SQL calls to the same overload report that the
#' UDF was unregistered.
#'
#' @param registration A [rducks_register()] result.
#' @return `NULL`, invisibly.
#' @export
rducks_unregister <- function(registration) {
  if (!inherits(registration, "rducks_registration")) {
    stop("registration must be a rducks_registration", call. = FALSE)
  }
  spec <- registration$spec
  sql <- sprintf(
    "SELECT rducks_unregister_scalar(%s, %s, %s) AS ok",
    rducks_sql_string(spec$name),
    rducks_sql_string(paste(spec$args, collapse = ",")),
    rducks_sql_string(spec$returns)
  )
  res <- DBI::dbGetQuery(registration$connection, sql)
  if (!NROW(res) || !isTRUE(res$ok[[1]])) {
    stop("native Rducks unregister failed for SQL function: ", spec$name, call. = FALSE)
  }
  rducks_callback_close(registration$callback)
  invisible(NULL)
}
