rducks_vectorized_column_values <- function(type, values, nulls, rows) {
  if (!length(rows)) {
    return(values[integer()])
  }
  if (any(nulls[rows]) && (rducks_uses_r_null_for_null(type) || !rducks_type_inherits(type, "rducks_scalar_type"))) {
    return(lapply(rows, function(i) rducks_value_at(type, values, nulls, i)))
  }
  values[rows]
}

rducks_vectorized_args <- function(arg_types, prepared, rows) {
  args <- vector("list", length(arg_types))
  for (col in seq_along(arg_types)) {
    args[col] <- list(rducks_vectorized_column_values(
      arg_types[[col]], prepared$columns[[col]], prepared$nulls[[col]], rows
    ))
  }
  args
}

rducks_vectorized_return_length <- function(type, value) {
  if (rducks_type_inherits(type, "rducks_struct_type") && is.data.frame(value)) {
    return(nrow(value))
  }
  length(value)
}

rducks_vectorized_return_value_at <- function(type, value, i) {
  if (rducks_type_inherits(type, "rducks_struct_type") && is.data.frame(value)) {
    row <- as.list(value[i, , drop = FALSE])
    children <- rducks_type_children(type)
    child_names <- rducks_type_child_names(type)
    for (field_index in seq_along(child_names)) {
      field <- child_names[[field_index]]
      child <- children[[field_index]]
      if ((!rducks_type_inherits(child, "rducks_scalar_type") || rducks_type_inherits(child, c("rducks_blob_type", "rducks_geometry_type", "rducks_variant_type", "rducks_bit_type"))) &&
          is.list(row[[field]]) && length(row[[field]]) == 1L) {
        # Single-bracket assignment so unwrapping a length-1 list whose element is
        # NULL keeps the field rather than deleting it from the row.
        row[field] <- row[[field]][1L]
      }
    }
    return(row)
  }
  if (is.list(value) && !is.data.frame(value) && !inherits(value, c("rducks_decimal", "rducks_interval", "rducks_bits"))) {
    return(value[[i]])
  }
  if (rducks_type_inherits(type, "rducks_scalar_type") && !rducks_type_inherits(type, c("rducks_blob_type", "rducks_geometry_type", "rducks_variant_type", "rducks_bit_type"))) {
    return(value[i])
  }
  if (rducks_type_inherits(type, c("rducks_decimal_type", "rducks_enum_type", "rducks_interval_type"))) {
    return(value[i])
  }
  value[[i]]
}

rducks_vectorized_fast_scalar_rows <- function(return_type, value, n) {
  .Call(RDUCKS_vectorized_fast_scalar_rows, return_type, value, as.integer(n))
}

rducks_vectorized_result_to_rows <- function(return_type, value, n) {
  n <- as.integer(n)
  if (is.null(value)) {
    return(vector("list", n))
  }
  fast_rows <- rducks_vectorized_fast_scalar_rows(return_type, value, n)
  if (!is.null(fast_rows)) {
    return(fast_rows)
  }
  actual <- rducks_vectorized_return_length(return_type, value)
  if (!identical(as.integer(actual), n)) {
    stop("vectorized return value must have length ", n, ", got ", actual, call. = FALSE)
  }
  rows <- vector("list", n)
  for (i in seq_len(n)) {
    rows[i] <- list(rducks_check_scalar_udf_return(
      return_type,
      rducks_vectorized_return_value_at(return_type, value, i)
    ))
  }
  rows
}

rducks_vectorized_eval_one <- function(fun, args, n, exception_handling) {
  tryCatch(
    do.call(fun, args),
    error = function(e) {
      if (identical(exception_handling, "return_null")) {
        return(structure(list(n = n), class = "rducks_return_null"))
      }
      stop(e)
    }
  )
}

rducks_vectorized_eval_prepared_chunk <- function(fun, arg_types, return_type, prepared,
                                                  null_handling, exception_handling) {
  arg_types <- rducks_resolve_dynamic_arg_types(arg_types, prepared$dynamic_arg_tokens %||% NULL)
  n <- as.integer(prepared$n %||% length(prepared$top_level_null))
  all_rows <- if (n) seq_len(n) else integer()
  eval_rows <- if (identical(null_handling, "default")) {
    which(!prepared$top_level_null)
  } else {
    all_rows
  }
  results <- vector("list", n)
  if (!length(eval_rows)) {
    return(results)
  }

  value <- rducks_vectorized_eval_one(
    fun,
    rducks_vectorized_args(arg_types, prepared, eval_rows),
    length(eval_rows),
    exception_handling
  )
  rows <- if (inherits(value, "rducks_return_null")) {
    vector("list", length(eval_rows))
  } else {
    rducks_vectorized_result_to_rows(return_type, value, length(eval_rows))
  }
  results[eval_rows] <- rows
  results
}


