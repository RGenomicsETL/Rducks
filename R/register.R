rducks_assert_row_marshalling_supported <- function(spec) {
  types <- c(spec$arg_types %||% rducks_as_type_list(spec$args), list(spec$return_type %||% rducks_as_type(spec$returns)))
  unsupported <- vapply(types, function(type) {
    if (rducks_row_mapping_supported(type)) "" else rducks_type_duckdb_sql(type)
  }, character(1))
  unsupported <- unsupported[nzchar(unsupported)]
  if (length(unsupported)) {
    stop(
      "row-mode marshalling is not implemented yet for: ",
      paste(unique(unsupported), collapse = ", "),
      call. = FALSE
    )
  }
  invisible(NULL)
}

#' Register an R UDF in DuckDB
#'
#' Registers a scalar R function as a DuckDB SQL function using the loaded Rducks
#' extension. Registration requires `external_threads=1` plus
#' `PRAGMA threads=1`; during execution, worker-thread UDF chunks are queued back
#' to the calling R thread.
#'
#' @param con A `duckdb_connection`.
#' @param name SQL function name.
#' @param fun R function.
#' @param args Argument type specification. Use exported DuckDB-style type
#'   objects such as `INTEGER`, `DOUBLE`, `INTEGER[]`, `INTEGER[3]`,
#'   `STRUCT(a = INTEGER)`, or `MAP(VARCHAR, INTEGER)`.
#' @param returns Return type specification.
#' @param mode Registration mode. `"row"` is implemented now and calls the R
#'   function once per DuckDB row through the nanoarrow row adapter.
#' @param null_handling Either `"default"` for NULL-in/NULL-out without calling
#'   the R function, or `"special"` to call the R function with the declared
#'   type's missing-value shape for NULL inputs (for example typed `NA` for
#'   ordinary scalar types and `NULL` for exact/exotic, binary, and composite
#'   values).
#' @param exception_handling Either `"rethrow"` to report R errors to DuckDB, or
#'   `"return_null"` to turn callback errors into SQL NULL values.
#' @param side_effects Logical scalar. Use `TRUE` for callbacks with randomness,
#'   counters, I/O, mutation, or other side effects so DuckDB does not treat the
#'   function as pure.
#' @return Object of class `rducks_registration` containing the connection,
#'   normalized signature, and registration options. The UDF remains registered
#'   in DuckDB even if this object is discarded.
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
  rducks_assert_single_thread(con)
  arrow_fun <- rducks_make_arrow_row_wrapper(fun, spec, null_handling, exception_handling)
  # The SQL registration call below is synchronous. `arrow_fun` is live in this
  # R frame until the DuckDB extension receives the address and preserves the
  # function in per-UDF metadata with R_PreserveObject().
  fun_ptr <- .Call(RDUCKS_sexp_addr, arrow_fun)
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
  structure(
    list(
      connection = con,
      spec = spec,
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
