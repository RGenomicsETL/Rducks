rducks_evaluator_ref_store <- function() {
  rducks_get_or_init_store("evaluator_refs")
}

rducks_assert_optional_function <- function(x, name) {
  if (!is.null(x) && !is.function(x)) {
    stop(name, " must be NULL or a function", call. = FALSE)
  }
  invisible(TRUE)
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

rducks_scalar_udf_registration_spec <- function(name, fun, args, returns, mode, dynamic_args = FALSE) {
  rducks_assert_non_empty_character_scalar(name, "name")
  if (!is.function(fun)) {
    stop("fun must be a function", call. = FALSE)
  }
  dynamic_args <- isTRUE(dynamic_args)
  arg_types <- if (dynamic_args) NULL else rducks_as_type_list(args)
  return_type <- rducks_as_type(returns)
  return_sql <- rducks_duckdb_types(return_type)
  list(
    name = name,
    args = if (dynamic_args) "*" else vapply(arg_types, rducks_type_token, character(1), USE.NAMES = FALSE),
    returns = rducks_type_token(return_type),
    arg_types = arg_types,
    return_type = return_type,
    dynamic_args = dynamic_args,
    mode = mode,
    signature = if (dynamic_args) sprintf("%s(...) -> %s", name, return_sql) else rducks_duckdb_signature(name, arg_types, return_type)
  )
}

rducks_assert_marshalling_supported <- function(spec) {
  types <- c(spec$arg_types %||% list(), list(spec$return_type))
  unsupported <- vapply(types, function(type) {
    if (rducks_scalar_mapping_supported(type)) "" else rducks_type_duckdb_sql(type)
  }, character(1))
  unsupported <- unsupported[nzchar(unsupported)]
  if (length(unsupported)) {
    stop(
      "DuckDB scalar-UDF ", spec$mode, " evaluation marshalling is not implemented yet for: ",
      paste(unique(unsupported), collapse = ", "),
      call. = FALSE
    )
  }
  invisible(NULL)
}

#' Register an R-backed DuckDB scalar UDF
#'
#' Registers an R function as a DuckDB scalar SQL function using the loaded
#' Rducks extension. In DuckDB terminology this is a scalar UDF: it returns one
#' SQL value for each logical input row. The `mode` argument is Rducks'
#' evaluation mode for that scalar UDF, not a DuckDB function kind:
#' `"scalar"` calls the R function once per logical row, while `"vectorized"`
#' calls the R function once per DuckDB chunk with vector/list-column inputs.
#'
#' Registration requires `external_threads=1` plus `PRAGMA threads=1` so native
#' registration and the default scalar evaluation path stay on the calling R
#' thread. The active \code{\link[=rducks_execution_plan]{rducks_execution_plan()}}
#' selects and freezes the marshalling/concurrency implementation for this
#' registration; unsupported plan/evaluation-mode/type combinations fail instead
#' of switching engines. If a later call registers the same SQL name/signature,
#' the callable implementation is replaced in the shared DuckDB database catalog
#' rather than being tied to the registering DBI connection. Choose the desired
#' execution plan before registration with
#' \code{\link[=rducks_set_execution_plan]{rducks_set_execution_plan()}}; the
#' selected evaluator/marshalling metadata is then stored with the native catalog
#' entry. R-backed UDF registrations are live DuckDB-runtime catalog entries,
#' not durable schema objects: they are visible to sibling connections while the
#' same DuckDB database runtime remains open, but a file-backed database must be
#' enabled and registered again after it is fully closed and reopened.
#'
#' @param con A `duckdb_connection`.
#' @param name SQL function name.
#' @param fun R function.
#' @param args Optional argument type specification. If omitted, Rducks registers
#'   a dynamic-varargs DuckDB scalar function. DuckDB resolves the concrete
#'   argument logical types at bind time, and Rducks materializes those inputs
#'   with the same typed semantics used for an explicit `args = ...` signature
#'   across scalar/vectorized direct evaluation. Use explicit `NULL` for a zero-argument scalar
#'   UDF. Otherwise use exported DuckDB-style type descriptors such as `INTEGER`,
#'   `DOUBLE`, `GEOMETRY`, `VARIANT`, `INTEGER[]`, `INTEGER[3]`,
#'   `STRUCT(a = INTEGER)`, or `MAP(VARCHAR, INTEGER)`. `VARIANT` signatures
#'   require a DuckDB runtime whose C API exposes VARIANT logical types.
#' @param returns Return type specification.
#' @param mode Rducks evaluation mode for this DuckDB scalar UDF. `"scalar"`
#'   calls the R function once per DuckDB row. `"vectorized"` calls the R
#'   function once per DuckDB chunk with one R vector/list-column per declared
#'   or dynamically bound argument.
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
#' @return Object of class `rducks_scalar_udf_registration` containing the
#'   connection, normalized signature, and registration options. The scalar UDF
#'   remains registered in DuckDB even if this object is discarded.
#' @examples
#' \donttest{
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db, threads = "single")
#' rducks_register_scalar_udf(db, "my_double", function(x) x * 2L,
#'   args = list(INTEGER), returns = INTEGER)
#' DBI::dbGetQuery(db, "SELECT my_double(3)")
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
#' @export
rducks_register_scalar_udf <- function(con, name, fun, args, returns,
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
  dynamic_args <- missing(args)
  if (missing(returns)) {
    stop("returns must be supplied", call. = FALSE)
  }
  spec <- rducks_scalar_udf_registration_spec(
    name, fun,
    args = if (dynamic_args) NULL else args,
    returns = returns,
    mode = mode,
    dynamic_args = dynamic_args
  )
  plan <- rducks_current_execution_plan(con)
  rducks_assert_marshalling_supported(spec)
  rducks_validate_execution_plan_for_registration(plan, spec)
  rducks_assert_single_thread(con)
  runtime_token <- rducks_attach_runtime_anchor(con)
  native_evaluator <- rducks_plan_native_evaluator_token(plan, spec$mode)
  eval_ref <- if (identical(spec$mode, "vectorized") && identical(plan$marshalling, "direct")) {
    rducks_make_rc_vectorized_bundle(fun, spec, null_handling, exception_handling, plan = plan)
  } else if (identical(spec$mode, "vectorized") && identical(plan$marshalling, "wire")) {
    rducks_make_wire_ipc_nng_vectorized_wrapper(
      fun, spec, null_handling, exception_handling, plan = plan, runtime_token = runtime_token
    )
  } else if (identical(plan$marshalling, "direct")) {
    rducks_make_rc_scalar_bundle(fun, spec, null_handling, exception_handling, plan = plan)
  } else if (identical(plan$marshalling, "wire")) {
    rducks_make_wire_ipc_nng_scalar_wrapper(
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
    rducks_sql_string(if (isTRUE(spec$dynamic_args)) "*" else paste(spec$args, collapse = ",")),
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
    class = "rducks_scalar_udf_registration"
  )
  rducks_store_registration(registration)
  registration
}

#' @export
print.rducks_scalar_udf_registration <- function(x, ...) {
  cat("<rducks_scalar_udf_registration>\n")
  cat("  registered:      ", if (isTRUE(x$registered)) "yes" else "no", "\n", sep = "")
  cat("  name:            ", x$spec$name, "\n", sep = "")
  cat("  evaluation_mode: ", x$spec$mode, "\n", sep = "")
  if (!is.null(x$execution_plan)) {
    cat("  plan:            ", x$execution_plan$plan_id, "\n", sep = "")
  }
  cat("  signature:       ", x$spec$signature, "\n", sep = "")
  invisible(x)
}

rducks_table_registration_spec <- function(name, fun, chunk_size) {
  rducks_assert_non_empty_character_scalar(name, "name")
  if (!is.function(fun)) {
    stop("fun must be a function", call. = FALSE)
  }
  if (!identical(typeof(fun), "closure")) {
    stop("fun must be an R closure with finite formal arguments", call. = FALSE)
  }
  if (!is.numeric(chunk_size) || length(chunk_size) != 1L || is.na(chunk_size) ||
      !is.finite(chunk_size) || chunk_size < 1 || chunk_size > 1024 || chunk_size != as.integer(chunk_size)) {
    stop("chunk_size must be an integer between 1 and 1024", call. = FALSE)
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


#' Create a streaming result for an Rducks table function
#'
#' Return this object from a function registered with
#' \code{\link[=rducks_register_table]{rducks_register_table()}} to expose a
#' finite table without materializing all rows during DuckDB bind. The
#' \code{prototype} supplies the output column names and types. During scan,
#' Rducks repeatedly calls \code{next_batch(n)} and imports each returned data
#' frame or named list. Return \code{NULL} from \code{next_batch()} to
#' signal end-of-stream.
#'
#' \code{close}, when supplied, is called at most once when the stream reaches
#' EOF. Rducks also tries to close unreached EOF streams when DuckDB releases
#' the native bind state on the recorded R thread, and a finalizer provides
#' eventual best-effort cleanup if the stream object is later garbage-collected.
#' Use it to release file handles, sockets, iterators, or other producer-side
#' resources. \code{cardinality} is optional scan metadata; set \code{exact =
#' TRUE} only when the stream will emit exactly that many rows.
#'
#' @param prototype Data frame or named list whose column names and R types
#'   define the stream schema. A zero-row prototype is usually appropriate.
#' @param next_batch Function called as \code{next_batch(n)} or
#'   \code{next_batch()} if it has no formal arguments. It must return the next
#'   batch or \code{NULL} for EOF.
#' @param close Optional cleanup function.
#' @param cardinality Optional non-negative row count, or \code{NA} when
#'   unknown.
#' @param exact Whether \code{cardinality} is exact rather than an estimate.
#' @return Object of class \code{rducks_table_stream}.
#' @examples
#' rows <- data.frame(x = 1:3)
#' i <- 0L
#' stream <- rducks_table_stream(
#'   prototype = rows[0, , drop = FALSE],
#'   next_batch = function(n) { i <<- i + 1L; if (i > 1L) NULL else rows }
#' )
#' stream
#' @export
rducks_table_stream <- function(prototype, next_batch, close = NULL,
                                cardinality = NA_real_, exact = FALSE) {
  prototype <- rducks_table_result_as_data_frame(prototype)
  if (!is.function(next_batch)) {
    stop("next_batch must be a function", call. = FALSE)
  }
  rducks_assert_optional_function(close, "close")
  if (!is.numeric(cardinality) || length(cardinality) != 1L || is.na(cardinality)) {
    cardinality <- NA_real_
  } else if (!is.finite(cardinality) || cardinality < 0 || cardinality != floor(cardinality)) {
    stop("cardinality must be NA or a non-negative integer-like number", call. = FALSE)
  }
  if (!is.logical(exact) || length(exact) != 1L || is.na(exact)) {
    stop("exact must be TRUE or FALSE", call. = FALSE)
  }
  state <- new.env(parent = emptyenv())
  state$next_batch <- next_batch
  state$close <- close
  state$closed <- FALSE
  state$cardinality <- cardinality
  state$exact <- exact
  reg.finalizer(state, function(env) {
    try(rducks_table_stream_finalize_state(env), silent = TRUE)
    invisible(NULL)
  }, onexit = TRUE)
  structure(
    list(prototype = prototype, state = state),
    class = "rducks_table_stream"
  )
}

rducks_table_is_stream <- function(x) inherits(x, "rducks_table_stream")

rducks_table_stream_prototype <- function(stream) {
  if (!rducks_table_is_stream(stream)) {
    stop("Rducks table stream object is invalid", call. = FALSE)
  }
  rducks_table_result_as_data_frame(stream$prototype)
}

rducks_table_stream_cardinality <- function(stream) {
  if (!rducks_table_is_stream(stream)) {
    stop("Rducks table stream object is invalid", call. = FALSE)
  }
  cardinality <- stream$state$cardinality
  if (is.na(cardinality)) {
    list(known = FALSE, rows = 0, exact = FALSE)
  } else {
    list(known = TRUE, rows = as.numeric(cardinality), exact = isTRUE(stream$state$exact))
  }
}

rducks_table_stream_finalize_state <- function(state) {
  if (is.null(state) || isTRUE(state$closed)) return(invisible(FALSE))
  state$closed <- TRUE
  if (is.function(state$close)) state$close()
  invisible(TRUE)
}

rducks_table_stream_close <- function(stream) {
  if (!rducks_table_is_stream(stream)) return(invisible(FALSE))
  rducks_table_stream_finalize_state(stream$state)
}

rducks_table_call_next_batch <- function(next_batch, n) {
  if (identical(typeof(next_batch), "closure")) {
    fmls <- formals(next_batch)
    if (is.null(fmls) || !length(fmls)) return(next_batch())
  }
  next_batch(as.integer(n))
}

rducks_table_stream_column_signature <- function(x) {
  if (inherits(x, "POSIXct")) return(list(kind = "POSIXct"))
  if (inherits(x, "Date")) return(list(kind = "Date"))
  if (inherits(x, "factor")) return(list(kind = "factor", levels = levels(x)))
  switch(typeof(x),
    logical = list(kind = "logical"),
    integer = list(kind = "integer"),
    double = list(kind = "numeric"),
    character = list(kind = "character"),
    list = {
      ok <- all(vapply(x, function(value) is.null(value) || is.raw(value), logical(1)))
      if (ok) return(list(kind = "blob_list"))
      stop(
        "Rducks table stream column type is unsupported; supported stream columns are logical, integer, numeric, character, factor, Date, POSIXct, and list-of-raw BLOB",
        call. = FALSE
      )
    },
    stop(
      "Rducks table stream column type is unsupported; supported stream columns are logical, integer, numeric, character, factor, Date, POSIXct, and list-of-raw BLOB",
      call. = FALSE
    )
  )
}

rducks_table_stream_validate_batch <- function(stream, batch) {
  batch <- rducks_table_result_as_data_frame(batch)
  expected <- names(stream$prototype)
  actual <- names(batch)
  if (!identical(actual, expected)) {
    stop("Rducks table stream next_batch columns must match the prototype names and order", call. = FALSE)
  }
  for (name in expected) {
    prototype_signature <- rducks_table_stream_column_signature(stream$prototype[[name]])
    batch_signature <- rducks_table_stream_column_signature(batch[[name]])
    if (!identical(batch_signature, prototype_signature)) {
      stop("Rducks table stream column ", name, " must match the prototype type", call. = FALSE)
    }
  }
  batch
}

rducks_table_stream_next_array <- function(stream, n) {
  if (!rducks_table_is_stream(stream)) {
    stop("Rducks table stream object is invalid", call. = FALSE)
  }
  state <- stream$state
  if (isTRUE(state$closed)) return(NULL)
  batch <- rducks_table_call_next_batch(state$next_batch, n)
  if (is.null(batch)) {
    rducks_table_stream_close(stream)
    return(NULL)
  }
  # In-process table scans share the address space with DuckDB, so hand the
  # validated data frame straight to the extension and let it fill DuckDB output
  # vectors directly. Serializing to a Quack wire payload here would add 2-3 full
  # copies for no benefit; the wire codec is reserved for the cross-process ipc
  # transport where data must actually leave the process.
  rducks_table_stream_validate_batch(stream, batch)
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

#' Register an R table function in DuckDB
#'
#' Registers an R function as a DuckDB table function. The R function is called on
#' the recorded R thread to produce either a finite result (a data frame or named
#' list of equal-length columns) or a
#' \code{\link[=rducks_table_stream]{rducks_table_stream()}} producer for
#' scan-time batches. Column types are inferred from the returned columns, and the
#' extension fills DuckDB output vectors directly from the R columns, with no
#' wire serialization for the in-process scan.
#'
#' @param con A `duckdb_connection`.
#' @param name SQL table function name.
#' @param fun R function returning a data frame, named list of columns, or
#'   \code{\link[=rducks_table_stream]{rducks_table_stream()}}. Its finite formal
#'   argument count defines the SQL positional argument count; each positional
#'   argument is registered as DuckDB `ANY` and converted at bind time from the
#'   actual SQL value.
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

rducks_aggregate_registration_spec <- function(name, update, finalize, args, returns, combine,
                                                update_chunk = NULL, combine_chunk = NULL, finalize_chunk = NULL,
                                                copy = NULL, copy_chunk = NULL) {
  rducks_assert_non_empty_character_scalar(name, "name")
  rducks_assert_optional_function(update, "update")
  rducks_assert_optional_function(finalize, "finalize")
  rducks_assert_optional_function(combine, "combine")
  rducks_assert_optional_function(copy, "copy")
  rducks_assert_optional_function(copy_chunk, "copy_chunk")
  rducks_assert_optional_function(update_chunk, "update_chunk")
  rducks_assert_optional_function(combine_chunk, "combine_chunk")
  rducks_assert_optional_function(finalize_chunk, "finalize_chunk")
  if (is.null(update) && is.null(update_chunk)) {
    stop("at least one of update or update_chunk must be supplied", call. = FALSE)
  }
  if (is.null(finalize) && is.null(finalize_chunk)) {
    stop("at least one of finalize or finalize_chunk must be supplied", call. = FALSE)
  }
  arg_types <- rducks_as_type_list(args)
  if (!length(arg_types)) {
    stop("Rducks aggregate UDFs require at least one input argument", call. = FALSE)
  }
  return_type <- rducks_as_type(returns)
  list(
    name = name,
    args = vapply(arg_types, rducks_type_token, character(1), USE.NAMES = FALSE),
    returns = rducks_type_token(return_type),
    arg_types = arg_types,
    return_type = return_type,
    signature = paste0(
      name,
      "(",
      paste(vapply(arg_types, rducks_type_duckdb_sql, character(1), USE.NAMES = FALSE), collapse = ", "),
      ") -> ",
      rducks_type_duckdb_sql(return_type)
    )
  )
}

#' Register an R aggregate function in DuckDB
#'
#' Registers an R-backed DuckDB aggregate. The aggregate state is an arbitrary R
#' object, not a serialized `raw` vector. Rducks stores a preserved reference to
#' the state object inside the native DuckDB aggregate state and passes that same
#' object back to later R callbacks. Returning `NULL` means "empty/no state";
#' use a wrapper such as `list(value = NULL)` if `NULL` itself must be
#' represented as a non-empty state.
#'
#' The row-wise API calls `update(state, ...)` for each selected input row and
#' `finalize(state)` for each output state. The vectorized update API calls
#' `update_chunk(states, group_id, ...)` once per DuckDB input chunk. `states` is
#' a list of the distinct aggregate-state objects referenced by that chunk, and
#' `group_id` is an integer vector with one entry per input row: `0L` means the
#' row was skipped by default NULL handling, otherwise the value is a one-based
#' index into `states`. The remaining arguments are full, unsliced R vectors for
#' the aggregate inputs. `update_chunk()` must return a list of replacement
#' states with the same length as `states`. `combine_chunk(left, right)` receives
#' lists of state objects for partial-state merging and must return a list with
#' one merged state per pair. `finalize_chunk(states)` must return a vector or
#' list with one scalar result per output state. Chunk callbacks take precedence
#' over row-wise callbacks.
#'
#' This API is deliberately serialized. Registration requires
#' `rducks_enable(con, threads = "single")` or equivalent
#' `external_threads=1` plus `PRAGMA threads=1`, and execution rejects attempts
#' to call R from non-calling DuckDB worker threads. If DuckDB combines partial
#' states and the target state is empty, Rducks preserves another reference to
#' the source R object rather than serializing or deep-copying it. Use `copy` or
#' `copy_chunk` when empty-target combine must create independent mutable state.
#' Merging two non-`NULL` states requires either `combine(left, right)` or
#' `combine_chunk(left, right)` and must still run on the recorded R thread.
#'
#' With `null_handling = "default"`, rows with any top-level SQL `NULL` input do
#' not call `update()` or appear in a positive `group_id` entry for
#' `update_chunk()`. Groups with no non-NULL rows therefore pass `NULL` to
#' `finalize()` or `finalize_chunk()`. With `null_handling = "special"`, update
#' callbacks receive the declared type's R missing-value shape for NULL inputs.
#'
#' @param con A `duckdb_connection`.
#' @param name SQL aggregate function name.
#' @param update Optional row-wise R function called as `update(state, ...)`;
#'   may return any R object state or `NULL`.
#' @param finalize Optional row-wise R function called as `finalize(state)`;
#'   must return a scalar compatible with `returns` or `NULL` for SQL `NULL`.
#' @param args Input type specification. Use exported DuckDB-style descriptors
#'   such as `INTEGER`, `DOUBLE`, or `VARCHAR`.
#' @param returns Return type specification.
#' @param combine Optional R function called as `combine(left, right)` when two
#'   non-`NULL` partial states must be merged. It may return any R object state
#'   or `NULL`.
#' @param null_handling Either `"default"` to skip rows with top-level NULL
#'   inputs, or `"special"` to pass missing values to update callbacks.
#' @param copy Optional R function called as `copy(state)` when DuckDB needs to
#'   place a non-`NULL` partial state into an empty target state during combine.
#'   When omitted, Rducks preserves another reference to the same R object.
#' @param copy_chunk Optional vectorized R function called as
#'   `copy_chunk(states)` with a list of states to copy. It must return a list
#'   of replacement states of the same length. It takes precedence over `copy()`.
#' @param update_chunk Optional vectorized R function called as
#'   `update_chunk(states, group_id, ...)`, where `states` is a list of current
#'   R state objects, `group_id` maps each input row to an element of `states`,
#'   and the remaining arguments are full R input vectors. It must return a list
#'   of replacement states with the same length as `states`.
#' @param combine_chunk Optional vectorized R function called as
#'   `combine_chunk(left_states, right_states)`, where both arguments are lists
#'   of R state objects or `NULL`. It must return a list of states of the same
#'   length.
#' @param finalize_chunk Optional vectorized R function called as
#'   `finalize_chunk(states)`, where `states` is a list of R state objects or
#'   `NULL`. It must return one result per state as either a vector or list.
#' @return Object of class `rducks_aggregate_registration` containing the
#'   connection and normalized aggregate signature. The aggregate remains
#'   registered in DuckDB even if this object is discarded.
#' @examples
#' \donttest{
#' db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#' rducks_enable(db, threads = "single")
#' rducks_register_aggregate(
#'   db, "my_sum",
#'   update = function(state, x) if (is.null(state)) x else state + x,
#'   finalize = function(state) if (is.null(state)) 0L else state,
#'   args = list(INTEGER), returns = INTEGER
#' )
#' DBI::dbGetQuery(db, "SELECT my_sum(x) FROM (VALUES (1), (2), (3)) t(x)")
#' rducks_release(db)
#' DBI::dbDisconnect(db)
#' }
#' @export
rducks_register_aggregate <- function(con, name, update = NULL, finalize = NULL, args, returns,
                                      combine = NULL,
                                      null_handling = c("default", "special"),
                                      copy = NULL, copy_chunk = NULL,
                                      update_chunk = NULL, combine_chunk = NULL, finalize_chunk = NULL) {
  null_handling <- match.arg(null_handling)
  if (!inherits(con, "duckdb_connection")) {
    stop("con must be a duckdb_connection", call. = FALSE)
  }
  spec <- rducks_aggregate_registration_spec(
    name, update, finalize, args, returns, combine,
    update_chunk = update_chunk, combine_chunk = combine_chunk, finalize_chunk = finalize_chunk,
    copy = copy, copy_chunk = copy_chunk
  )
  rducks_assert_variant_materializable(c(spec$arg_types, list(spec$return_type)), "aggregate")
  rducks_assert_single_thread(con)
  rducks_attach_runtime_anchor(con)
  bundle <- list(
    update = update, combine = combine, finalize = finalize,
    update_chunk = update_chunk, combine_chunk = combine_chunk, finalize_chunk = finalize_chunk,
    copy = copy, copy_chunk = copy_chunk
  )
  eval_ref_handle <- rducks_evaluator_ref_put(bundle)
  on.exit(rducks_evaluator_ref_remove(eval_ref_handle), add = TRUE)
  sql <- sprintf(
    "SELECT rducks_register_aggregate(%s, %s, %s, %s, %s, %s) AS ok",
    rducks_sql_string(name),
    rducks_sql_string(eval_ref_handle$id),
    rducks_sql_string(eval_ref_handle$token),
    rducks_sql_string(paste(spec$args, collapse = ",")),
    rducks_sql_string(spec$returns),
    rducks_sql_string(null_handling)
  )
  res <- DBI::dbGetQuery(con, sql)
  if (!NROW(res) || !isTRUE(res$ok[[1]])) {
    stop("native Rducks aggregate registration failed for SQL function: ", name, call. = FALSE)
  }
  structure(
    list(
      connection = con,
      spec = spec,
      null_handling = null_handling,
      registered = TRUE
    ),
    class = "rducks_aggregate_registration"
  )
}

#' @export
print.rducks_aggregate_registration <- function(x, ...) {
  cat("<rducks_aggregate_registration>\n")
  cat("  registered: ", if (isTRUE(x$registered)) "yes" else "no", "\n", sep = "")
  cat("  name:       ", x$spec$name, "\n", sep = "")
  cat("  signature:  ", x$spec$signature, "\n", sep = "")
  invisible(x)
}
