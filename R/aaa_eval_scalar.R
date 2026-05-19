rducks_scalar_prepare_dynamic_inputs <- function(input_array, input_schema, n) {
  input_children <- input_array$children
  input_schema_children <- input_schema$children
  arity <- length(input_children)
  if (length(input_schema_children) != arity) {
    stop("dynamic Rducks scalar input schema does not match input array", call. = FALSE)
  }

  columns <- vector("list", arity)
  nulls <- vector("list", arity)
  for (i in seq_len(arity)) {
    child <- input_children[[i]]
    schema_child <- input_schema_children[[i]]
    nanoarrow::nanoarrow_array_set_schema(child, schema_child, validate = FALSE)
    columns[[i]] <- nanoarrow::convert_array(child)
    nulls[[i]] <- !rducks_arrow_validity(child, n)
  }

  top_level_null <- rep(FALSE, n)
  for (i in seq_along(nulls)) {
    top_level_null <- top_level_null | nulls[[i]]
  }

  list(columns = columns, nulls = nulls, top_level_null = top_level_null, n = n, dynamic_args = TRUE)
}

rducks_scalar_prepare_inputs <- function(arg_types, input_array, input_schema, n) {
  n <- as.integer(n)
  if (!nanoarrow::nanoarrow_pointer_is_valid(input_array)) {
    stop("input nanoarrow array pointer is not valid", call. = FALSE)
  }
  if (!nanoarrow::nanoarrow_pointer_is_valid(input_schema)) {
    stop("input nanoarrow schema pointer is not valid", call. = FALSE)
  }
  if (is.null(arg_types)) {
    return(rducks_scalar_prepare_dynamic_inputs(input_array, input_schema, n))
  }

  input_children <- input_array$children
  input_schema_children <- input_schema$children
  columns <- vector("list", length(arg_types))
  nulls <- vector("list", length(arg_types))
  for (i in seq_along(arg_types)) {
    columns[[i]] <- rducks_arrow_array_to_values(arg_types[[i]], input_children[[i]], input_schema_children[[i]])
    nulls[[i]] <- if (inherits(arg_types[[i]], "rducks_union_type")) rep(FALSE, n) else !rducks_arrow_validity(input_children[[i]], n)
  }

  top_level_null <- rep(FALSE, n)
  for (i in seq_along(nulls)) {
    top_level_null <- top_level_null | nulls[[i]]
  }

  list(columns = columns, nulls = nulls, top_level_null = top_level_null, n = n)
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
    args[col] <- list(rducks_arrow_value_at(
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
        return(structure(list(), class = "rducks_arrow_return_null"))
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
    if (inherits(value, "rducks_arrow_return_null")) {
      results[row] <- list(NULL)
    } else {
      value <- rducks_check_scalar_udf_return(return_type, value)
      results[row] <- list(value)
    }
  }
  results
}

rducks_scalar_results_to_arrow <- function(return_type, results, output_schema, n) {
  rducks_arrow_result_array(return_type, results, output_schema, n)
}
