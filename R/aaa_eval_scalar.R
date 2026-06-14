# Prepared-inputs shape consumed by the row/chunk evaluators:
#   list(columns, nulls, top_level_null, n[, dynamic_args])
# Inputs arrive either as Rducks values materialized from a quack wire payload
# (worker processes, in-process slow path) or as SEXP columns built directly
# by the extension's direct evaluator on the recorded R thread.

rducks_native_prepared_inputs <- function(arg_types, values, n, nulls = NULL) {
  n <- as.integer(n)
  columns <- values
  if (is.null(nulls)) {
    nulls <- lapply(seq_along(columns), function(i) {
      type <- if (is.null(arg_types)) NULL else arg_types[[i]]
      if (!is.null(type) && rducks_type_inherits(type, "rducks_union_type")) {
        return(rep(FALSE, n))
      }
      column <- columns[[i]]
      # Scalar/value-class columns get type-aware missing detection. This is
      # required for the value classes that are themselves classed lists
      # (rducks_decimal, rducks_interval): a generic is.list() check would
      # inspect their fields rather than their rows. rducks_native_scalar_nulls
      # returns per-row validity, so the row nulls are its negation.
      if (!is.null(type) &&
          rducks_type_inherits(type, c("rducks_scalar_type", "rducks_decimal_type", "rducks_enum_type"))) {
        return(!rducks_native_scalar_nulls(type, column))
      }
      if (is.data.frame(column)) {
        rep(FALSE, n)
      } else if (is.list(column) && !inherits(column, c("Date", "POSIXct", "POSIXlt", "difftime"))) {
        vapply(column, is.null, logical(1))
      } else {
        is.na(column)
      }
    })
  }
  top_level_null <- rep(FALSE, n)
  for (i in seq_along(nulls)) {
    top_level_null <- top_level_null | nulls[[i]]
  }
  out <- list(columns = columns, nulls = nulls, top_level_null = top_level_null, n = n)
  if (is.null(arg_types)) out$dynamic_args <- TRUE
  out
}

rducks_wire_prepared_inputs <- function(arg_types, input_payload, n) {
  if (is.null(arg_types)) {
    stop("dynamic varargs are not on the Rducks wire yet", call. = FALSE)
  }
  decoded <- rducks_wire_decode_values(arg_types, input_payload)
  if (!identical(decoded$rows, as.integer(n))) {
    stop("Rducks wire payload row count disagrees with the chunk row count", call. = FALSE)
  }
  rducks_native_prepared_inputs(arg_types, decoded$values, n)
}

rducks_scalar_dynamic_value_at <- function(column, nulls, row) {
  if (is.data.frame(column)) {
    return(column[row, , drop = FALSE])
  }
  if (is.list(column) && !inherits(column, c("Date", "POSIXct", "POSIXlt", "difftime"))) {
    return(column[[row]])
  }
  column[row]
}

rducks_scalar_args_at <- function(arg_types, prepared, row) {
  if (isTRUE(prepared$dynamic_args)) {
    args <- vector("list", length(prepared$columns))
    for (col in seq_along(prepared$columns)) {
      args[col] <- list(rducks_scalar_dynamic_value_at(prepared$columns[[col]], prepared$nulls[[col]], row))
    }
    return(args)
  }

  args <- vector("list", length(arg_types))
  for (col in seq_along(arg_types)) {
    args[col] <- list(rducks_value_at(
      arg_types[[col]], prepared$columns[[col]], prepared$nulls[[col]], row
    ))
  }
  args
}

rducks_scalar_eval_one <- function(fun, args, exception_handling) {
  tryCatch(
    do.call(fun, args),
    error = function(e) {
      if (identical(exception_handling, "return_null")) {
        return(structure(list(), class = "rducks_return_null"))
      }
      stop(e)
    }
  )
}

rducks_scalar_eval_prepared_rows <- function(fun, arg_types, return_type, prepared,
                                             null_handling, exception_handling) {
  n <- as.integer(prepared$n %||% length(prepared$top_level_null))
  results <- vector("list", n)
  for (row in seq_len(n)) {
    if (isTRUE(prepared$top_level_null[[row]]) && identical(null_handling, "default")) {
      results[row] <- list(NULL)
      next
    }

    value <- rducks_scalar_eval_one(
      fun,
      rducks_scalar_args_at(arg_types, prepared, row),
      exception_handling
    )
    if (inherits(value, "rducks_return_null")) {
      results[row] <- list(NULL)
    } else {
      value <- rducks_check_scalar_udf_return(return_type, value)
      results[row] <- list(value)
    }
  }
  results
}

rducks_scalar_results_to_wire <- function(return_type, results, output_schema, n) {
  # output_schema is retained for call-shape compatibility; quack payloads are
  # self-describing and carry the declared return type themselves.
  rducks_quack_results_payload(return_type, results, as.integer(n))
}
