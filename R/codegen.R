rducks_match_mode <- function(mode) {
  match.arg(mode, names(rducks_mode_semantics_rows))
}

#' Create an Rducks UDF specification
#'
#' @param name SQL function name.
#' @param fun R function.
#' @param args Rducks type objects or scalar type tokens.
#' @param returns Rducks return type object or scalar type token.
#' @param mode Registration mode. `"scalar"` is implemented now and calls the R
#'   function once per DuckDB row through the native Rducks DuckDB extension.
#' @return Object of class `rducks_udf_spec`.
#' @export
rducks_udf_spec <- function(name, fun, args, returns, mode = "scalar") {
  mode <- rducks_match_mode(mode)
  if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)) {
    stop("name must be a non-empty character scalar", call. = FALSE)
  }
  if (!is.function(fun)) {
    stop("fun must be a function", call. = FALSE)
  }
  arg_types <- rducks_as_type_list(args)
  return_type <- rducks_as_type(returns)
  args <- vapply(arg_types, rducks_type_token, character(1), USE.NAMES = FALSE)
  returns <- rducks_type_token(return_type)
  argument_type_mapping <- rducks_argument_type_mapping(arg_types)
  structure(
    list(
      name = name,
      fun = fun,
      args = args,
      returns = returns,
      arg_types = arg_types,
      return_type = return_type,
      mode = mode,
      signature = rducks_duckdb_signature(name, arg_types, return_type),
      argument_type_mapping = argument_type_mapping
    ),
    class = "rducks_udf_spec"
  )
}

#' @export
print.rducks_udf_spec <- function(x, ...) {
  cat("<rducks_udf_spec>\n")
  cat("  name:      ", x$name, "\n", sep = "")
  cat("  mode:      ", x$mode, "\n", sep = "")
  cat("  signature: ", x$signature, "\n", sep = "")
  invisible(x)
}
