rducks_evaluator_ref_store <- function() {
  store <- .rducks_state$evaluator_refs
  if (is.null(store)) {
    store <- new.env(parent = emptyenv())
    .rducks_state$evaluator_refs <- store
  }
  store
}

rducks_next_evaluator_id <- function() {
  counter <- .rducks_state$evaluator_ref_counter %||% 0
  counter <- counter + 1
  .rducks_state$evaluator_ref_counter <- counter
  paste0("rducks-evaluator-", counter)
}

rducks_evaluator_ref_token <- function(id) {
  counter <- .rducks_state$evaluator_ref_token_counter %||% 0
  counter <- counter + 1
  .rducks_state$evaluator_ref_token_counter <- counter
  paste(
    id,
    Sys.getpid(),
    format(Sys.time(), "%Y%m%d%H%M%OS6", tz = "UTC"),
    counter,
    sep = "-"
  )
}

rducks_evaluator_ref_put <- function(eval_ref) {
  id <- rducks_next_evaluator_id()
  token <- rducks_evaluator_ref_token(id)
  assign(id, list(token = token, value = eval_ref), envir = rducks_evaluator_ref_store())
  list(id = id, token = token)
}

rducks_evaluator_ref_get <- function(id, token) {
  if (!is.character(id) || length(id) != 1L || is.na(id) || !nzchar(id) ||
      !is.character(token) || length(token) != 1L || is.na(token) || !nzchar(token)) {
    stop("invalid Rducks evaluator handle", call. = FALSE)
  }
  store <- rducks_evaluator_ref_store()
  if (!exists(id, envir = store, inherits = FALSE)) {
    stop("invalid Rducks evaluator handle", call. = FALSE)
  }
  record <- get(id, envir = store, inherits = FALSE)
  if (!identical(record$token, token)) {
    stop("invalid Rducks evaluator handle", call. = FALSE)
  }
  record$value
}

rducks_evaluator_ref_remove <- function(handle) {
  if (!is.list(handle) || is.null(handle$id)) return(invisible(NULL))
  store <- .rducks_state$evaluator_refs
  if (!is.null(store) && exists(handle$id, envir = store, inherits = FALSE)) {
    rm(list = handle$id, envir = store)
  }
  invisible(NULL)
}

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

#' Register an R UDF in DuckDB
#'
#' Registers an R function as a DuckDB SQL function using the loaded Rducks
#' extension. Registration requires `external_threads=1` plus
#' `PRAGMA threads=1` so native registration and the default scalar execution
#' path stay on the calling R thread. The active \code{\link[=rducks_execution_plan]{rducks_execution_plan()}}
#' selects and freezes the marshalling implementation for this registration;
#' unsupported plan/mode/type combinations fail instead of switching engines. If a
#' later call registers the same SQL name/signature, the callable implementation
#' is replaced in the shared DuckDB database catalog rather than being tied to
#' the registering DBI connection. After registration, use \code{\link[=rducks_enable_inproc]{rducks_enable_inproc()}}
#' to opt into queued same-process execution. For `arrow_ipc` plans, the UDF
#' closure and discovered globals are copied once to each NNG worker in the
#' shared provider pool and retained for that pool's lifetime.
#'
#' @param con A `duckdb_connection`.
#' @param name SQL function name.
#' @param fun R function.
#' @param args Argument type specification. Use `NULL` for a zero-argument
#'   scalar UDF. Otherwise use exported DuckDB-style type descriptors such as
#'   `INTEGER`, `DOUBLE`, `INTEGER[]`, `INTEGER[3]`, `STRUCT(a = INTEGER)`, or
#'   `MAP(VARCHAR, INTEGER)`.
#' @param returns Return type specification.
#' @param mode Registration mode. `"scalar"` calls the R function once per
#'   DuckDB row. `"vectorized"` calls the R function once per DuckDB chunk with
#'   one R vector/list-column per declared argument.
#' @param null_handling Either `"default"` for NULL-in/NULL-out without calling
#'   the R function, or `"special"` to call the R function with the declared
#'   type's missing-value shape for NULL inputs (for example typed `NA` for
#'   ordinary scalar types and `NULL` for exact/exotic, binary, and composite
#'   values).
#' @param exception_handling Either `"rethrow"` to report user R function
#'   errors to DuckDB, or `"return_null"` to turn user R function errors into
#'   SQL NULL values. Return type-checking and marshalling errors still abort
#'   the query.
#' @param side_effects Logical scalar. Use `TRUE` for functions with randomness,
#'   counters, I/O, mutation, or other side effects so DuckDB does not treat the
#'   function as pure.
#' @return Object of class `rducks_registration` containing the connection,
#'   normalized signature, and registration options. The UDF remains registered
#'   in DuckDB even if this object is discarded.
#' @export
rducks_register <- function(con, name, fun, args, returns,
                            mode = "scalar",
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
  spec <- rducks_registration_spec(name, fun, args, returns, mode = mode)
  plan <- rducks_current_execution_plan(con)
  rducks_assert_arrow_marshalling_supported(spec)
  rducks_validate_execution_plan_for_registration(plan, spec)
  rducks_assert_single_thread(con)
  runtime_token <- rducks_attach_runtime_anchor(con)
  native_evaluator <- rducks_plan_native_evaluator_token(plan, spec$mode)
  eval_ref <- if (identical(spec$mode, "vectorized") && identical(plan$marshalling, "arrow_r")) {
    rducks_make_arrow_vectorized_wrapper(fun, spec, null_handling, exception_handling, plan = plan)
  } else if (identical(spec$mode, "vectorized") && identical(plan$marshalling, "arrow_c")) {
    rducks_make_rc_vectorized_bundle(fun, spec, null_handling, exception_handling, plan = plan)
  } else if (identical(spec$mode, "vectorized") && identical(plan$marshalling, "arrow_ipc")) {
    rducks_make_arrow_ipc_nng_vectorized_wrapper(
      fun, spec, null_handling, exception_handling, plan = plan, runtime_token = runtime_token
    )
  } else if (identical(plan$marshalling, "arrow_r")) {
    rducks_make_arrow_scalar_wrapper(fun, spec, null_handling, exception_handling, plan = plan)
  } else if (identical(plan$marshalling, "arrow_c")) {
    rducks_make_rc_scalar_bundle(fun, spec, null_handling, exception_handling, plan = plan)
  } else if (identical(plan$marshalling, "arrow_ipc")) {
    rducks_make_arrow_ipc_nng_scalar_wrapper(
      fun, spec, null_handling, exception_handling, plan = plan, runtime_token = runtime_token
    )
  } else {
    stop("Rducks execution plan ", plan$plan_id, " is not implemented for local registration", call. = FALSE)
  }
  if (is.list(eval_ref) && identical(eval_ref$provider, "nng") && is.function(eval_ref$prepare)) {
    eval_ref$prepare()
  }
  # The SQL registration call below is synchronous. `eval_ref` is held in a
  # temporary R-side registry while the DuckDB extension looks it up by opaque
  # evaluator id + token and then preserves it in per-UDF metadata with
  # R_PreserveObject(). Do not expose raw SEXP addresses through SQL.
  eval_ref_handle <- rducks_evaluator_ref_put(eval_ref)
  on.exit(rducks_evaluator_ref_remove(eval_ref_handle), add = TRUE)
  sql <- sprintf(
    "SELECT rducks_register_scalar(%s, %s, %s, %s, %s, %s, %s, %s, %s) AS ok",
    rducks_sql_string(name),
    rducks_sql_string(eval_ref_handle$id),
    rducks_sql_string(eval_ref_handle$token),
    rducks_sql_string(paste(spec$args, collapse = ",")),
    rducks_sql_string(spec$returns),
    rducks_sql_string(null_handling),
    rducks_sql_string(exception_handling),
    if (isTRUE(side_effects)) "TRUE" else "FALSE",
    rducks_sql_string(native_evaluator)
  )
  res <- DBI::dbGetQuery(con, sql)
  if (!NROW(res) || !isTRUE(res$ok[[1]])) {
    stop("native Rducks registration failed for SQL function: ", name, call. = FALSE)
  }
  registration <- structure(
    list(
      connection = con,
      spec = spec,
      null_handling = null_handling,
      exception_handling = exception_handling,
      side_effects = side_effects,
      execution_plan = plan,
      registered = TRUE
    ),
    class = "rducks_registration"
  )
  rducks_store_registration(registration)
  registration
}

#' @export
print.rducks_registration <- function(x, ...) {
  cat("<rducks_registration>\n")
  cat("  registered: ", if (isTRUE(x$registered)) "yes" else "no", "\n", sep = "")
  cat("  name:       ", x$spec$name, "\n", sep = "")
  cat("  mode:       ", x$spec$mode, "\n", sep = "")
  if (!is.null(x$execution_plan)) {
    cat("  plan:       ", x$execution_plan$plan_id, "\n", sep = "")
  }
  cat("  signature:  ", x$spec$signature, "\n", sep = "")
  invisible(x)
}

rducks_table_registration_spec <- function(name, fun, chunk_size) {
  if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)) {
    stop("name must be a non-empty character scalar", call. = FALSE)
  }
  if (!is.function(fun)) {
    stop("fun must be a function", call. = FALSE)
  }
  if (!is.numeric(chunk_size) || length(chunk_size) != 1L || is.na(chunk_size) ||
      !is.finite(chunk_size) || chunk_size < 1 || chunk_size > 1024 || chunk_size != as.integer(chunk_size)) {
    stop("chunk_size must be an integer between 1 and 1024", call. = FALSE)
  }
  if (!identical(typeof(fun), "closure")) {
    stop("fun must be an R closure with finite formal arguments", call. = FALSE)
  }
  table_formals <- formals(fun)
  if (is.null(table_formals)) table_formals <- pairlist()
  parameter_names <- names(table_formals) %||% rep.int("", length(table_formals))
  if ("..." %in% parameter_names) {
    stop("rducks_register_table() does not support variadic ... arguments", call. = FALSE)
  }
  parameter_count <- length(table_formals)
  if (parameter_count > 64L) {
    stop("rducks_register_table() supports at most 64 SQL arguments", call. = FALSE)
  }
  list(
    name = name,
    parameter_count = as.integer(parameter_count),
    chunk_size = as.integer(chunk_size),
    signature = paste0(
      name,
      "(",
      paste(rep.int("ANY", parameter_count), collapse = ", "),
      ") -> TABLE(<bind-time schema>)"
    )
  )
}

rducks_table_result_as_data_frame <- function(result) {
  if (is.data.frame(result)) return(result)
  if (!is.list(result)) {
    stop("Rducks table function must return a data frame or named list", call. = FALSE)
  }
  column_names <- names(result)
  if (is.null(column_names) || anyNA(column_names) || any(!nzchar(column_names))) {
    stop("Rducks table function result columns must be named", call. = FALSE)
  }
  if (anyDuplicated(column_names)) {
    stop("Rducks table function result column names must be unique", call. = FALSE)
  }
  if (!length(result)) {
    stop("Rducks table function must return at least one column", call. = FALSE)
  }
  lengths <- vapply(result, length, integer(1))
  if (length(unique(lengths)) != 1L) {
    stop("Rducks table result columns must have equal lengths", call. = FALSE)
  }
  structure(result, names = column_names, class = "data.frame", row.names = .set_row_names(lengths[[1L]]))
}

rducks_table_as_arrow_array <- function(result) {
  if (inherits(result, "nanoarrow_array")) return(result)
  stream <- if (inherits(result, "nanoarrow_array_stream")) {
    result
  } else {
    nanoarrow::as_nanoarrow_array_stream(rducks_table_result_as_data_frame(result))
  }
  batches <- nanoarrow::collect_array_stream(stream)
  if (length(batches) != 1L) {
    stop("Rducks table nanoarrow stream must yield exactly one record batch", call. = FALSE)
  }
  batches[[1L]]
}

#' Register an R table function in DuckDB
#'
#' Registers a first-slice R-backed DuckDB table function. The registered SQL
#' table function infers its positional SQL argument count from `formals(fun)`
#' and registers those arguments with DuckDB's dynamic `ANY` type. During
#' DuckDB's bind phase, Rducks converts the actual SQL argument values to R
#' scalars/lists, calls `fun(...)` on the recorded calling R thread, and infers
#' the DuckDB output schema from the returned data frame or named list of
#' equal-length columns. It then converts the result through a nanoarrow Arrow C
#' Data stream, imports it into a DuckDB chunk, and emits slices of that imported
#' chunk during table-function scans.
#'
#' This is intentionally separate from scalar/vectorized UDF registration: table
#' functions have their own bind/init/scan state and currently support only the
#' one-shot finite table shape. DuckDB table functions can have bind-time dynamic
#' schemas and broad input signatures; this first Rducks API follows that model
#' for output schemas and positional input types, while the number of SQL
#' arguments is fixed by the R function's formal argument count. Variadic `...`
#' arguments are not supported. If you already have a static R data frame to
#' expose as a virtual table, prefer `duckdb::duckdb_register()`; DuckDB's R
#' package routes that through its native data-frame scan path. Use
#' `rducks_enable(con, threads = "single")` or otherwise set `external_threads=1`
#' plus `PRAGMA threads=1` before registration and execution; worker-thread calls
#' into R are rejected.
#'
#' @param con A `duckdb_connection`.
#' @param name SQL table function name.
#' @param fun R function returning a data frame or named list of columns. Its
#'   finite formal argument count defines the SQL positional argument count;
#'   each positional argument is registered as DuckDB `ANY` and converted at
#'   bind time from the actual SQL value.
#' @param chunk_size Maximum number of rows emitted per DuckDB output chunk.
#'   Must be an integer from 1 to 1024.
#' @return Object of class `rducks_table_registration` containing the
#'   connection and normalized table signature. The table function remains
#'   registered in DuckDB even if this object is discarded.
#' @export
rducks_register_table <- function(con, name, fun, chunk_size = 1024L) {
  if (!inherits(con, "duckdb_connection")) {
    stop("con must be a duckdb_connection", call. = FALSE)
  }
  spec <- rducks_table_registration_spec(name, fun, chunk_size)
  rducks_assert_single_thread(con)
  rducks_attach_runtime_anchor(con)
  eval_ref_handle <- rducks_evaluator_ref_put(fun)
  on.exit(rducks_evaluator_ref_remove(eval_ref_handle), add = TRUE)
  sql <- sprintf(
    "SELECT rducks_register_table(%s, %s, %s, %d::UBIGINT, %d::UBIGINT) AS ok",
    rducks_sql_string(name),
    rducks_sql_string(eval_ref_handle$id),
    rducks_sql_string(eval_ref_handle$token),
    spec$parameter_count,
    spec$chunk_size
  )
  res <- DBI::dbGetQuery(con, sql)
  if (!NROW(res) || !isTRUE(res$ok[[1]])) {
    stop("native Rducks table registration failed for SQL function: ", name, call. = FALSE)
  }
  structure(
    list(
      connection = con,
      spec = spec,
      registered = TRUE
    ),
    class = "rducks_table_registration"
  )
}

#' @export
print.rducks_table_registration <- function(x, ...) {
  cat("<rducks_table_registration>\n")
  cat("  registered: ", if (isTRUE(x$registered)) "yes" else "no", "\n", sep = "")
  cat("  name:       ", x$spec$name, "\n", sep = "")
  cat("  signature:  ", x$spec$signature, "\n", sep = "")
  invisible(x)
}
