#' Create an Rducks UDF specification
#'
#' @param name SQL function name.
#' @param fun R function.
#' @param args Character vector of Rducks type tokens.
#' @param returns Return type token.
#' @param mode Registration mode, currently `"generic"` or `"compiled"`.
#' @return Object of class `rducks_udf_spec`.
#' @export
rducks_udf_spec <- function(name, fun, args, returns, mode = c("generic", "compiled")) {
  mode <- match.arg(mode)
  if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)) {
    stop("name must be a non-empty character scalar", call. = FALSE)
  }
  if (!is.function(fun)) {
    stop("fun must be a function", call. = FALSE)
  }
  args <- rducks_types_normalize(args)
  returns <- rducks_type_normalize(returns)
  structure(
    list(
      name = name,
      fun = fun,
      args = args,
      returns = returns,
      mode = mode,
      signature = rducks_duckdb_signature(name, args, returns)
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

rducks_c_identifier <- function(x) {
  x <- gsub("[^A-Za-z0-9_]", "_", x)
  if (!grepl("^[A-Za-z_]", x)) {
    x <- paste0("_", x)
  }
  x
}

#' Generate C source for a scalar wrapper shape
#'
#' Generates the shape-specific source that Rducks will compile via Rtinycc for
#' the compiled registration path. The source intentionally calls placeholder
#' runtime functions; the DuckDB extension will provide those symbols.
#'
#' @param spec A [rducks_udf_spec()] object.
#' @param callback_id Integer callback id or C expression naming the callback.
#' @return Character scalar C source.
#' @export
rducks_generate_scalar_wrapper <- function(spec, callback_id = "callback_id") {
  if (!inherits(spec, "rducks_udf_spec")) {
    stop("spec must be a rducks_udf_spec", call. = FALSE)
  }
  fn <- paste0("rducks_wrap_", rducks_c_identifier(spec$name))
  args <- spec$args
  ret <- spec$returns

  arg_decl <- if (length(args)) {
    paste(sprintf("void *arg%d", seq_along(args) - 1L), collapse = ", ")
  } else {
    "void"
  }

  unpack <- character()
  for (i in seq_along(args)) {
    info <- rducks_type_info(args[[i]])
    unpack <- c(unpack, sprintf("  %s a%d = *(%s *)arg%d;", info$c, i - 1L, info$c, i - 1L))
  }

  ret_info <- rducks_type_info(ret)
  call_args <- if (length(args)) {
    paste(sprintf("rducks_arg_from_%s(a%d)", args, seq_along(args) - 1L), collapse = ", ")
  } else {
    ""
  }

  paste(
    "#include <stdint.h>",
    "#include <stdbool.h>",
    "typedef struct rducks_arg rducks_arg;",
    "typedef struct rducks_result rducks_result;",
    sprintf("extern rducks_arg rducks_arg_from_%s(%s);", unique(args),
      vapply(unique(args), function(tok) rducks_type_info(tok)$c, character(1))
    ),
    "extern bool rducks_call_callback(int callback_id, const rducks_arg *args, int n_args, rducks_result *out);",
    sprintf("extern %s rducks_result_as_%s(const rducks_result *result);", ret_info$c, ret),
    "",
    sprintf("bool %s(%s, void *out_value, bool *out_is_null) {", fn, arg_decl),
    unpack,
    sprintf("  rducks_arg args[%d];", max(length(args), 1L)),
    if (length(args)) sprintf("  rducks_arg tmp[%d] = { %s };", length(args), call_args) else "  rducks_arg *tmp = 0;",
    if (length(args)) sprintf("  for (int i = 0; i < %d; i++) args[i] = tmp[i];", length(args)) else "  (void)args;",
    "  rducks_result result;",
    sprintf("  if (!rducks_call_callback((int)(%s), %s, %d, &result)) {", callback_id, if (length(args)) "args" else "0", length(args)),
    "    if (out_is_null) *out_is_null = true;",
    "    return false;",
    "  }",
    sprintf("  *(%s *)out_value = rducks_result_as_%s(&result);", ret_info$c, ret),
    "  if (out_is_null) *out_is_null = false;",
    "  return true;",
    "}",
    sep = "\n"
  )
}
