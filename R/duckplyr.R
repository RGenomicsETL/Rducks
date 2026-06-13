rducks_duckplyr_normalize_returns <- function(returns) {
  if (rducks_type_inherits(returns, "rducks_type") || (is.character(returns) && length(returns) == 1L && is.null(names(returns)))) {
    returns <- list(returns)
  } else if (is.character(returns)) {
    returns <- as.list(returns)
  }
  if (!is.list(returns) || !length(returns)) {
    stop("returns must be a non-empty named list of Rducks return types", call. = FALSE)
  }
  names <- names(returns)
  if (is.null(names) || anyNA(names) || any(!nzchar(names)) || anyDuplicated(names)) {
    stop("returns must be named by R function/SQL UDF name", call. = FALSE)
  }
  returns
}

rducks_duckplyr_rewrite_calls <- function(expr, names) {
  if (is.call(expr)) {
    head <- expr[[1L]]
    if (is.symbol(head) && as.character(head) %in% names) {
      expr[[1L]] <- as.call(list(as.name("$"), as.name("dd"), as.name(as.character(head))))
    }
    if (length(expr) > 1L) {
      for (i in seq.int(2L, length(expr))) {
        expr[[i]] <- rducks_duckplyr_rewrite_calls(expr[[i]], names)
      }
    }
  }
  expr
}

rducks_duckplyr_register_udfs <- function(con, returns, env,
                                          null_handling, exception_handling,
                                          side_effects, mode = "scalar") {
  if (!is.logical(side_effects) || length(side_effects) != 1L || is.na(side_effects)) {
    stop("side_effects must be TRUE or FALSE", call. = FALSE)
  }
  mode <- rducks_match_mode(mode)
  names <- names(returns)
  registrations <- vector("list", length(names))
  names(registrations) <- names
  for (name in names) {
    fun <- get0(name, envir = env, mode = "function", inherits = TRUE)
    if (is.null(fun)) {
      stop("cannot find R function for duckplyr/Rducks UDF: ", name, call. = FALSE)
    }
    registrations[[name]] <- rducks_register_scalar_udf(
      con = con,
      name = name,
      fun = fun,
      returns = returns[[name]],
      mode = mode,
      null_handling = null_handling,
      exception_handling = exception_handling,
      side_effects = side_effects
    )
  }
  registrations
}

rducks_duckplyr_eval_expr <- function(con, expr, returns, env,
                                      null_handling = c("default", "special"),
                                      exception_handling = c("rethrow", "return_null"),
                                      side_effects = FALSE,
                                      mode = "scalar") {
  rducks_assert_duckdb_connection(con)
  null_handling <- match.arg(null_handling)
  exception_handling <- match.arg(exception_handling)
  returns <- rducks_duckplyr_normalize_returns(returns)
  rducks_duckplyr_register_udfs(
    con, returns, env,
    null_handling = null_handling,
    exception_handling = exception_handling,
    side_effects = side_effects,
    mode = mode
  )
  rewritten <- rducks_duckplyr_rewrite_calls(expr, names(returns))
  eval(rewritten, envir = env)
}

#' Evaluate a duckplyr pipeline with dynamic Rducks scalar UDFs
#'
#' Registers selected R functions as dynamic-argument Rducks scalar UDFs on a
#' DuckDB connection, rewrites matching calls in a captured duckplyr expression
#' to duckplyr's DuckDB-function escape hatch, and evaluates the rewritten
#' expression. This lets a duckplyr pipeline stay in DuckDB for those calls
#' instead of falling back to dplyr, provided every registered function has an
#' explicit return type.
#'
#' This helper intentionally requires return-type declarations: DuckDB needs a
#' scalar function's return type during planning even when its input arguments
#' are accepted dynamically. Dynamic arguments are a duckplyr-oriented
#' convenience path that uses Rducks' direct DuckDB-vector input conversion. The
#' duckplyr bridge defaults to `mode = "scalar"` because ordinary R calls in
#' duckplyr SQL expressions are written as row-wise scalar functions. Set
#' `mode = "vectorized"` only for helpers that accept full vectors/chunks and
#' return a vector of the same length. The selected Rducks execution plan is
#' still taken from `con`, so the in-process plan from
#' \code{\link[=rducks_execution_plan]{rducks_execution_plan()}} applies; set it
#' with \code{\link[=rducks_set_execution_plan]{rducks_set_execution_plan()}}
#' before evaluating the duckplyr expression. Use explicit `args` in
#' \code{\link[=rducks_register_scalar_udf]{rducks_register_scalar_udf()}}
#' when you need Rducks' declared composite, exotic, or special-NULL input
#' semantics.
#'
#' @param con A `duckdb_connection` with Rducks enabled.
#' @param expr A duckplyr expression or pipeline to evaluate.
#' @param returns Named list or named character vector of return types. Names
#'   must be R function names visible from `env`; values are Rducks type
#'   descriptors or scalar type tokens, e.g. `list(score_fun = DOUBLE)`.
#' @param env Evaluation environment for `expr` and function lookup.
#' @param null_handling,exception_handling,side_effects Passed to
#'   \code{\link[=rducks_register_scalar_udf]{rducks_register_scalar_udf()}}.
#' @param mode Rducks scalar-UDF evaluation mode for registered helpers.
#'   `"scalar"` calls the R helper once per row; `"vectorized"` calls it once
#'   per DuckDB chunk and requires a vectorized helper.
#' @return The value of the evaluated expression.
#' @export
rducks_with_duckplyr <- function(con, expr, returns, env = parent.frame(),
                                 null_handling = c("default", "special"),
                                 exception_handling = c("rethrow", "return_null"),
                                 side_effects = FALSE,
                                 mode = "scalar") {
  expr <- substitute(expr)
  rducks_duckplyr_eval_expr(
    con, expr, returns, env,
    null_handling = null_handling,
    exception_handling = exception_handling,
    side_effects = side_effects,
    mode = mode
  )
}

#' @rdname rducks_with_duckplyr
#' @param data A `duckdb_connection` with Rducks enabled.
#' @param ... Reserved for future extensions; must be empty.
#' @param rducks_returns Named return-type list for dynamic Rducks UDFs.
#' @param rducks_env Evaluation environment for `expr` and function lookup.
#' @param rducks_mode Rducks scalar-UDF evaluation mode for helpers registered
#'   through `with.duckdb_connection()`.
#' @export
with.duckdb_connection <- function(data, expr, ..., rducks_returns, rducks_env = parent.frame(), rducks_mode = "scalar") {
  expr <- substitute(expr)
  if (missing(rducks_returns)) {
    return(eval(expr, data, enclos = rducks_env))
  }
  dots <- list(...)
  if (length(dots)) {
    stop("unused arguments in with.duckdb_connection(): ", paste(names(dots), collapse = ", "), call. = FALSE)
  }
  rducks_duckplyr_eval_expr(data, expr, rducks_returns, rducks_env, mode = rducks_mode)
}
