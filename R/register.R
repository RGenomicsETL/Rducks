#' Register an R UDF in DuckDB
#'
#' Registers a scalar R function as a DuckDB SQL function using the loaded Rducks
#' extension. The current implemented path supports one- or two-argument
#' `f64 -> f64`/`f64, f64 -> f64` callbacks and requires [rducks_enable()] first.
#'
#' @param con A `duckdb_connection`.
#' @param name SQL function name.
#' @param fun R function.
#' @param args Character vector of Rducks type tokens. Currently all must be
#'   `"f64"` and length must be one or two.
#' @param returns Return type token. Currently must be `"f64"`.
#' @param mode Reserved for future generic/compiled paths.
#' @param compile Reserved for future Rtinycc-generated wrapper paths.
#' @return Object of class `rducks_registration`.
#' @export
rducks_register <- function(con, name, fun, args, returns,
                            mode = c("generic", "compiled"),
                            compile = identical(mode[[1]], "compiled")) {
  mode <- match.arg(mode)
  force(compile)
  if (!inherits(con, "duckdb_connection")) {
    stop("con must be a duckdb_connection", call. = FALSE)
  }
  spec <- rducks_udf_spec(name, fun, args, returns, mode = mode)
  if (!identical(spec$returns, "f64") || !(length(spec$args) %in% c(1L, 2L)) || any(spec$args != "f64")) {
    stop("current Rducks backend only supports f64 unary/binary scalar UDFs", call. = FALSE)
  }

  callback <- rducks_callback(fun)
  ok <- FALSE
  on.exit({
    if (!ok) rducks_callback_close(callback)
  }, add = TRUE)

  ptr <- .Call(RDUCKS_callback_fun_addr, callback)
  sql <- sprintf(
    "SELECT rducks_register_f64(%s, %s::UBIGINT, %d::INTEGER) AS ok",
    rducks_sql_string(name),
    as.character(ptr),
    length(spec$args)
  )
  res <- DBI::dbGetQuery(con, sql)
  if (!NROW(res) || !isTRUE(res$ok[[1]])) {
    stop("native Rducks registration failed for SQL function: ", name, call. = FALSE)
  }
  ok <- TRUE

  structure(
    list(connection = con, spec = spec, callback = callback, registered = TRUE),
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
