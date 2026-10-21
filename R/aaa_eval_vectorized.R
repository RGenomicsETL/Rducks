rducks_vectorized_column_values <- function(type, values, nulls, rows) {
  if (!length(rows)) {
    return(values[integer()])
  }
  all_rows <- length(rows) == length(values)
  if (any(if (all_rows) nulls else nulls[rows]) &&
      (rducks_uses_r_null_for_null(type) || !rducks_type_inherits(type, "rducks_scalar_type"))) {
    return(lapply(rows, function(i) rducks_value_at(type, values, nulls, i)))
  }
  if (all_rows) values else values[rows]
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
  # Under "rethrow" the error propagates unchanged, so the tryCatch frame is
  # only needed for the "return_null" policy.
  if (!identical(exception_handling, "return_null")) {
    return(do.call(fun, args))
  }
  tryCatch(
    do.call(fun, args),
    error = function(e) structure(list(n = n), class = "rducks_return_null")
  )
}

# Scalar tokens whose canonical R vector (logical, integer, double, character
# with NA for NULL) can be written to DuckDB in bulk without per-row values.
rducks_fast_atomic_tokens <- c("bool", "i8", "u8", "i16", "u16", "i32", "u32", "f32", "f64", "varchar")

rducks_fast_na_template <- function(token) {
  switch(token,
    bool = NA,
    i8 = , u8 = , i16 = , u16 = , i32 = NA_integer_,
    u32 = , f32 = , f64 = NA_real_,
    varchar = NA_character_,
    stop("no fast NA template for token ", token, call. = FALSE)
  )
}

rducks_fast_atomic_token <- function(type) {
  if (!rducks_type_inherits(type, "rducks_scalar_type")) return(NA_character_)
  token <- rducks_type_token(type)
  if (token %in% rducks_fast_atomic_tokens) token else NA_character_
}

# Expand a result computed for eval_rows back to all n rows with NA elsewhere.
rducks_fast_expand_rows <- function(value, token, n, eval_rows) {
  if (is.null(eval_rows)) return(value)
  full <- rep(rducks_fast_na_template(token), n)
  full[eval_rows] <- value
  full
}

# Fast result shapes for the direct (in-process) path. Returns an atomic vector
# for a plain scalar return, an "rducks_columnar_result" list for a STRUCT
# returned as a data frame or named list of columns, or NULL when the value is
# not in a fast shape (the caller then uses the generic per-row conversion,
# which also produces the generic error for an invalid value).
rducks_vectorized_direct_result <- function(return_type, value, n, eval_rows) {
  n_eval <- if (is.null(eval_rows)) n else length(eval_rows)
  token <- rducks_fast_atomic_token(return_type)
  if (!is.na(token)) {
    if (is.list(value) || is.null(.Call(RDUCKS_vectorized_fast_scalar_check, return_type, value, n_eval))) {
      return(NULL)
    }
    return(rducks_fast_expand_rows(value, token, n, eval_rows))
  }
  if (rducks_type_inherits(return_type, "rducks_struct_type")) {
    return(rducks_vectorized_columnar_struct(return_type, value, n, eval_rows))
  }
  NULL
}

rducks_vectorized_columnar_struct <- function(type, value, n, eval_rows) {
  if (!is.list(value) || is.null(names(value))) return(NULL)
  n_eval <- if (is.null(eval_rows)) n else length(eval_rows)
  if (is.data.frame(value)) {
    if (nrow(value) != n_eval) return(NULL)
  }
  children <- rducks_type_children(type)
  child_names <- rducks_type_child_names(type)
  if (!all(child_names %in% names(value))) return(NULL)
  columns <- vector("list", length(children))
  for (i in seq_along(children)) {
    child <- children[[i]]
    col <- value[[child_names[[i]]]]
    token <- rducks_fast_atomic_token(child)
    if (!is.na(token)) {
      if (is.list(col) || is.null(.Call(RDUCKS_vectorized_fast_scalar_check, child, col, n_eval))) return(NULL)
      columns[[i]] <- rducks_fast_expand_rows(col, token, n, eval_rows)
    } else if (rducks_type_inherits(child, "rducks_struct_type")) {
      nested <- rducks_vectorized_columnar_struct(child, col, n, eval_rows)
      if (is.null(nested)) return(NULL)
      columns[[i]] <- nested
    } else if (rducks_type_inherits(child, c("rducks_blob_type", "rducks_geometry_type"))) {
      rows <- .Call(RDUCKS_vectorized_fast_scalar_rows, child, col, n_eval)
      if (is.null(rows)) return(NULL)
      if (!is.null(eval_rows)) {
        full <- vector("list", n)
        full[eval_rows] <- rows
        rows <- full
      }
      columns[[i]] <- rows
    } else {
      return(NULL)
    }
  }
  row_null <- if (is.null(eval_rows)) NULL else {
    mask <- rep(TRUE, n)
    mask[eval_rows] <- FALSE
    mask
  }
  structure(columns, class = "rducks_columnar_result", rducks_row_null = row_null)
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

# Direct (in-process) variant: same evaluation, but a plain scalar or STRUCT
# result in a fast shape is returned as an atomic vector / columnar list for
# bulk writeback in the extension instead of a per-row list.
rducks_vectorized_eval_prepared_chunk_direct <- function(fun, arg_types, return_type, prepared,
                                                         null_handling, exception_handling) {
  arg_types <- rducks_resolve_dynamic_arg_types(arg_types, prepared$dynamic_arg_tokens %||% NULL)
  n <- as.integer(prepared$n %||% length(prepared$top_level_null))
  all_rows <- if (n) seq_len(n) else integer()
  eval_rows <- if (identical(null_handling, "default")) {
    which(!prepared$top_level_null)
  } else {
    all_rows
  }
  if (!length(eval_rows)) {
    return(vector("list", n))
  }

  value <- rducks_vectorized_eval_one(
    fun,
    rducks_vectorized_args(arg_types, prepared, eval_rows),
    length(eval_rows),
    exception_handling
  )
  if (inherits(value, "rducks_return_null")) {
    return(vector("list", n))
  }
  skipped <- if (length(eval_rows) == n) NULL else eval_rows
  fast <- rducks_vectorized_direct_result(return_type, value, n, skipped)
  if (!is.null(fast)) {
    return(fast)
  }
  results <- vector("list", n)
  results[eval_rows] <- rducks_vectorized_result_to_rows(return_type, value, length(eval_rows))
  results
}


