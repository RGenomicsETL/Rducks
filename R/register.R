#' Register an R UDF specification
#'
#' Creates and preserves an R callback token and returns an Rducks registration
#' object. The native DuckDB extension registration path is intentionally staged:
#' the returned object contains all metadata required by either the generic
#' bridge or the Rtinycc-compiled bridge.
#'
#' @param con A `duckdb_connection`.
#' @param name SQL function name.
#' @param fun R function.
#' @param args Character vector of Rducks type tokens.
#' @param returns Return type token.
#' @param mode Registration mode.
#' @param compile If `TRUE`, include generated scalar wrapper source for the
#'   compiled path.
#' @return Object of class `rducks_registration`.
#' @export
rducks_register <- function(con, name, fun, args, returns,
                            mode = c("generic", "compiled"),
                            compile = identical(mode[[1]], "compiled")) {
  if (!inherits(con, "duckdb_connection")) {
    stop("con must be a duckdb_connection", call. = FALSE)
  }
  mode <- match.arg(mode)
  spec <- rducks_udf_spec(name, fun, args, returns, mode = mode)
  callback <- rducks_callback(fun)
  source <- NULL
  if (isTRUE(compile)) {
    source <- rducks_generate_scalar_wrapper(spec)
  }
  out <- structure(
    list(
      connection = con,
      spec = spec,
      callback = callback,
      source = source,
      registered = FALSE
    ),
    class = "rducks_registration"
  )
  out
}

#' @export
print.rducks_registration <- function(x, ...) {
  cat("<rducks_registration>\n")
  cat("  registered: ", if (isTRUE(x$registered)) "yes" else "no", "\n", sep = "")
  print(x$spec)
  if (!is.null(x$source)) {
    cat("  generated source: yes\n")
  }
  invisible(x)
}

#' Close an Rducks registration
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
