.rducks_compiled_registry <- new.env(parent = emptyenv())
.rducks_compiled_registry$next_id <- 0L

rducks_keep_compiled_wrapper <- function(compiled) {
  .rducks_compiled_registry$next_id <- .rducks_compiled_registry$next_id + 1L
  id <- paste0("wrapper_", .rducks_compiled_registry$next_id)
  .rducks_compiled_registry[[id]] <- compiled
  id
}

rducks_drop_compiled_wrapper <- function(id) {
  if (is.character(id) && length(id) == 1L && exists(id, envir = .rducks_compiled_registry, inherits = FALSE)) {
    rm(list = id, envir = .rducks_compiled_registry)
  }
  invisible(NULL)
}

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
#' extension and an Rtinycc-generated shape-specific C wrapper. The current
#' implemented path is direct main-R-thread callback execution and requires
#' single-thread DuckDB execution.
#'
#' @param con A `duckdb_connection`.
#' @param name SQL function name.
#' @param fun R function.
#' @param args Argument type specification. Use exported DuckDB-style type
#'   objects such as `INTEGER`, `DOUBLE`, `INTEGER[]`, `INTEGER[3]`,
#'   `STRUCT(a = INTEGER)`, or `MAP(VARCHAR, INTEGER)`.
#' @param returns Return type specification.
#' @param mode Registration mode. `"row"` is implemented now and calls the R
#'   function once per row through an Rtinycc wrapper. `"arrow_lapply"` and
#'   `"arrow_nanoarrow"` are reserved for future batch UDF paths.
#' @param compile Kept for API compatibility; must be `TRUE`.
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
                            mode = c("row", "arrow_lapply", "arrow_nanoarrow"),
                            compile = TRUE,
                            null_handling = c("default", "special"),
                            exception_handling = c("rethrow", "return_null"),
                            side_effects = FALSE) {
  mode <- rducks_match_mode(mode)
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
  if (identical(mode, "arrow_lapply")) {
    stop("mode = 'arrow_lapply' is reserved for a future Arrow-batch lapply UDF path", call. = FALSE)
  }
  if (identical(mode, "arrow_nanoarrow")) {
    rducks_assert_nanoarrow()
    stop("mode = 'arrow_nanoarrow' is reserved for a future Arrow C Data Interface UDF path", call. = FALSE)
  }
  rducks_assert_row_marshalling_supported(spec)
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
  compiled_ptr <- .Call(RDUCKS_sexp_addr, compiled)
  sql <- sprintf(
    "SELECT rducks_register_scalar(%s, %s::UBIGINT, %s::UBIGINT, %s::UBIGINT, %s, %s, %s, %s, %s) AS ok",
    rducks_sql_string(name),
    as.character(fun_ptr),
    as.character(wrapper_ptr),
    as.character(compiled_ptr),
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

#' Soft-unregister an Rducks registration
#'
#' DuckDB currently registers extension scalar functions as internal catalog
#' entries, so SQL `DROP FUNCTION` cannot remove them. `rducks_unregister()`
#' replaces the matching overload with an inactive stub, releases Rducks' R-side
#' callback token, and drops the package registry reference to the compiled
#' wrapper. Future SQL calls to the same overload report that the UDF was
#' unregistered.
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
  rducks_drop_compiled_wrapper(registration$compiled_registry_id)
  invisible(NULL)
}
