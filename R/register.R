#' Register an R UDF in DuckDB
#'
#' This is the intended public registration entry point. It currently errors
#' because the loaded DuckDB extension bridge is not implemented in this repo
#' yet. Keeping the function as an explicit failure is preferable to returning a
#' metadata object that looks registered but is not visible to DuckDB.
#'
#' @param con A `duckdb_connection`.
#' @param name SQL function name.
#' @param fun R function.
#' @param args Character vector of Rducks type tokens.
#' @param returns Return type token.
#' @param mode Planned registration mode.
#' @param compile Planned compiled-wrapper flag.
#' @return Currently does not return; errors until the native DuckDB extension
#'   registration path exists.
#' @export
rducks_register <- function(con, name, fun, args, returns,
                            mode = c("generic", "compiled"),
                            compile = identical(mode[[1]], "compiled")) {
  mode <- match.arg(mode)
  force(con)
  force(name)
  force(fun)
  force(args)
  force(returns)
  force(compile)
  stop(
    "rducks_register() is not implemented yet: ",
    "the native DuckDB extension registration bridge is missing",
    call. = FALSE
  )
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
