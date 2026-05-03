rducks_registration_spec <- function(name, fun, args, returns, mode) {
  if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)) {
    stop("name must be a non-empty character scalar", call. = FALSE)
  }
  if (!is.function(fun)) {
    stop("fun must be a function", call. = FALSE)
  }
  arg_types <- rducks_as_type_list(args)
  return_type <- rducks_as_type(returns)
  list(
    name = name,
    args = vapply(arg_types, rducks_type_token, character(1), USE.NAMES = FALSE),
    returns = rducks_type_token(return_type),
    arg_types = arg_types,
    return_type = return_type,
    mode = mode,
    signature = rducks_duckdb_signature(name, arg_types, return_type)
  )
}

rducks_assert_arrow_marshalling_supported <- function(spec) {
  types <- c(spec$arg_types, list(spec$return_type))
  unsupported <- vapply(types, function(type) {
    if (rducks_scalar_mapping_supported(type)) "" else rducks_type_duckdb_sql(type)
  }, character(1))
  unsupported <- unsupported[nzchar(unsupported)]
  if (length(unsupported)) {
    stop(
      spec$mode, "-mode marshalling is not implemented yet for: ",
      paste(unique(unsupported), collapse = ", "),
      call. = FALSE
    )
  }
  invisible(NULL)
}

rducks_assert_vectorized_supported <- function(spec, eval_mode) {
  if (!identical(spec$mode, "vectorized")) {
    return(invisible(NULL))
  }
  if (!identical(eval_mode, "R")) {
    stop("mode = 'vectorized' currently supports eval_mode = 'R' only", call. = FALSE)
  }
  if (!length(spec$arg_types)) {
    stop("mode = 'vectorized' currently requires at least one declared argument", call. = FALSE)
  }
  invisible(NULL)
}

#' Register an R UDF in DuckDB
#'
#' Registers an R function as a DuckDB SQL function using the loaded Rducks
#' extension. Registration requires `external_threads=1` plus
#' `PRAGMA threads=1` so native registration and the default scalar execution
#' path stay on the calling R thread. After registration, use
#' [rducks_enable_inproc()] to opt into queued same-process execution.
#'
#' @param con A `duckdb_connection`.
#' @param name SQL function name.
#' @param fun R function.
#' @param args Argument type specification. Use exported DuckDB-style type
#'   objects such as `INTEGER`, `DOUBLE`, `INTEGER[]`, `INTEGER[3]`,
#'   `STRUCT(a = INTEGER)`, or `MAP(VARCHAR, INTEGER)`.
#' @param returns Return type specification.
#' @param mode Registration mode. `"scalar"` calls the R function once per
#'   DuckDB row. `"vectorized"` calls the R function once per DuckDB chunk with
#'   one R vector/list-column per declared argument.
#' @param eval_mode Scalar evaluator implementation. `"R"` uses the R/nanoarrow
#'   adapter; `"RC"` uses the native C row-loop adapter and validates against the
#'   same scalar-mode semantics. `mode = "vectorized"` currently supports
#'   `eval_mode = "R"` only.
#' @param null_handling Either `"default"` for NULL-in/NULL-out without calling
#'   the R function, or `"special"` to call the R function with the declared
#'   type's missing-value shape for NULL inputs (for example typed `NA` for
#'   ordinary scalar types and `NULL` for exact/exotic, binary, and composite
#'   values).
#' @param exception_handling Either `"rethrow"` to report R errors to DuckDB, or
#'   `"return_null"` to turn R errors into SQL NULL values.
#' @param side_effects Logical scalar. Use `TRUE` for functions with randomness,
#'   counters, I/O, mutation, or other side effects so DuckDB does not treat the
#'   function as pure.
#' @return Object of class `rducks_registration` containing the connection,
#'   normalized signature, and registration options. The UDF remains registered
#'   in DuckDB even if this object is discarded.
#' @export
rducks_register <- function(con, name, fun, args, returns,
                            mode = "scalar",
                            eval_mode = c("R", "RC"),
                            null_handling = c("default", "special"),
                            exception_handling = c("rethrow", "return_null"),
                            side_effects = FALSE) {
  mode <- rducks_match_mode(mode)
  eval_mode <- match.arg(eval_mode)
  null_handling <- match.arg(null_handling)
  exception_handling <- match.arg(exception_handling)
  if (!is.logical(side_effects) || length(side_effects) != 1L || is.na(side_effects)) {
    stop("side_effects must be TRUE or FALSE", call. = FALSE)
  }
  if (!inherits(con, "duckdb_connection")) {
    stop("con must be a duckdb_connection", call. = FALSE)
  }
  spec <- rducks_registration_spec(name, fun, args, returns, mode = mode)
  rducks_assert_arrow_marshalling_supported(spec)
  rducks_assert_vectorized_supported(spec, eval_mode)
  rducks_assert_single_thread(con)
  eval_ref <- if (identical(mode, "vectorized")) {
    rducks_make_arrow_vectorized_wrapper(fun, spec, null_handling, exception_handling)
  } else if (identical(eval_mode, "R")) {
    rducks_make_arrow_scalar_wrapper(fun, spec, null_handling, exception_handling)
  } else {
    rducks_make_rc_scalar_bundle(fun, spec, null_handling, exception_handling)
  }
  # The SQL registration call below is synchronous. `eval_ref` is live in this
  # R frame until the DuckDB extension receives the address and preserves it in
  # per-UDF metadata with R_PreserveObject().
  eval_ref_ptr <- .Call(RDUCKS_sexp_addr, eval_ref)
  sql <- sprintf(
    "SELECT rducks_register_scalar(%s, %s::UBIGINT, %s, %s, %s, %s, %s, %s) AS ok",
    rducks_sql_string(name),
    as.character(eval_ref_ptr),
    rducks_sql_string(paste(spec$args, collapse = ",")),
    rducks_sql_string(spec$returns),
    rducks_sql_string(null_handling),
    rducks_sql_string(exception_handling),
    if (isTRUE(side_effects)) "TRUE" else "FALSE",
    rducks_sql_string(eval_mode)
  )
  res <- DBI::dbGetQuery(con, sql)
  if (!NROW(res) || !isTRUE(res$ok[[1]])) {
    stop("native Rducks registration failed for SQL function: ", name, call. = FALSE)
  }
  structure(
    list(
      connection = con,
      spec = spec,
      null_handling = null_handling,
      exception_handling = exception_handling,
      side_effects = side_effects,
      eval_mode = eval_mode,
      registered = TRUE
    ),
    class = "rducks_registration"
  )
}

#' @export
print.rducks_registration <- function(x, ...) {
  cat("<rducks_registration>\n")
  cat("  registered: ", if (isTRUE(x$registered)) "yes" else "no", "\n", sep = "")
  cat("  name:       ", x$spec$name, "\n", sep = "")
  cat("  mode:       ", x$spec$mode, "\n", sep = "")
  cat("  eval_mode:  ", x$eval_mode %||% "R", "\n", sep = "")
  cat("  signature:  ", x$spec$signature, "\n", sep = "")
  invisible(x)
}
