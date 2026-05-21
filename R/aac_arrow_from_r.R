# R-to-Arrow result materialization helpers.
#
# Kept separate from aab_arrow_materialize.R so Arrow array decoding and
# scalar-UDF return encoding can evolve independently.

rducks_arrow_results_as <- function(results, null_value, coerce, prototype) {
  vapply(results, function(x) if (is.null(x)) null_value else coerce(x)[[1L]], prototype)
}

rducks_arrow_results_as_logical <- function(results) {
  rducks_arrow_results_as(results, NA, as.logical, logical(1))
}

rducks_arrow_results_as_integer <- function(results) {
  rducks_arrow_results_as(results, NA_integer_, as.integer, integer(1))
}

rducks_arrow_results_as_numeric <- function(results) {
  rducks_arrow_results_as(results, NA_real_, as.numeric, numeric(1))
}

rducks_arrow_results_as_character <- function(results) {
  rducks_arrow_results_as(results, NA_character_, as.character, character(1))
}

rducks_scalar_udf_return_needs_length_one <- function(type) {
  if (rducks_type_inherits(type, c("rducks_decimal_type", "rducks_enum_type"))) {
    return(TRUE)
  }
  rducks_type_inherits(type, "rducks_scalar_type") && !rducks_type_inherits(type, c("rducks_blob_type", "rducks_geometry_type", "rducks_variant_type", "rducks_bit_type"))
}

rducks_normalize_scalar_udf_return <- function(type, value) {
  if (rducks_type_inherits(type, "rducks_decimal_type") && inherits(value, "rducks_decimal")) {
    params <- rducks_type_parameters(type)
    return(rducks_decimal(as.character(value), params$width, params$scale))
  }
  value
}

rducks_check_scalar_udf_return <- function(type, value) {
  value <- rducks_normalize_scalar_udf_return(type, value)
  if (is.null(value)) {
    return(NULL)
  }
  rducks_check_return(type, value)
  if (rducks_scalar_udf_return_needs_length_one(type) && length(value) != 1L) {
    stop("return value must have length 1", call. = FALSE)
  }
  value
}

rducks_arrow_sequence_value_at <- function(type, value, j) {
  if (rducks_type_inherits(type, "rducks_scalar_type")) {
    if (rducks_type_inherits(type, c("rducks_blob_type", "rducks_geometry_type", "rducks_variant_type", "rducks_bit_type"))) return(value[[j]])
    return(value[j])
  }
  if (rducks_type_inherits(type, c("rducks_decimal_type", "rducks_enum_type", "rducks_interval_type"))) {
    if (is.list(value) && !inherits(value, c("rducks_decimal", "rducks_enum", "rducks_interval"))) {
      return(value[[j]])
    }
    return(value[j])
  }
  value[[j]]
}

rducks_arrow_scalar_values_to_array <- S7::new_generic(
  "rducks_arrow_scalar_values_to_array",
  "type",
  function(type, results, schema) S7::S7_dispatch()
)

S7::method(rducks_arrow_scalar_values_to_array, rducks_bool_type_class) <- function(type, results, schema) {
  rducks_arrow_bool_array(rducks_arrow_results_as_logical(results), schema)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_i8_type_class) <- function(type, results, schema) {
  rducks_arrow_integer_storage_array(rducks_arrow_results_as_integer(results), schema, 1L, signed = TRUE)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_u8_type_class) <- function(type, results, schema) {
  rducks_arrow_integer_storage_array(rducks_arrow_results_as_integer(results), schema, 1L, signed = FALSE)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_i16_type_class) <- function(type, results, schema) {
  rducks_arrow_integer_storage_array(rducks_arrow_results_as_integer(results), schema, 2L, signed = TRUE)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_u16_type_class) <- function(type, results, schema) {
  rducks_arrow_integer_storage_array(rducks_arrow_results_as_integer(results), schema, 2L, signed = FALSE)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_i32_type_class) <- function(type, results, schema) {
  rducks_arrow_integer_storage_array(rducks_arrow_results_as_integer(results), schema, 4L, signed = TRUE)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_r_integer_scalar_type_class) <- function(type, results, schema) {
  rducks_arrow_integer_storage_array(rducks_arrow_results_as_integer(results), schema, 4L, signed = TRUE)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_u32_type_class) <- function(type, results, schema) {
  rducks_arrow_integer_storage_array(rducks_arrow_results_as_numeric(results), schema, 4L, signed = FALSE)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_f32_type_class) <- function(type, results, schema) {
  rducks_arrow_float_array(rducks_arrow_results_as_numeric(results), schema, 4L)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_f64_type_class) <- function(type, results, schema) {
  rducks_arrow_float_array(rducks_arrow_results_as_numeric(results), schema, 8L)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_varchar_type_class) <- function(type, results, schema) {
  rducks_arrow_string_array(rducks_arrow_results_as_character(results), schema)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_date_type_class) <- function(type, results, schema) {
  days <- rducks_arrow_results_as_numeric(results)
  rducks_arrow_integer_storage_array(days, schema, 4L, signed = TRUE)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_time_type_class) <- function(type, results, schema) {
  rducks_arrow_time_array(rducks_arrow_results_as_numeric(results), schema)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_timestamp_type_class) <- function(type, results, schema) {
  values <- as.POSIXct(rducks_arrow_results_as_numeric(results), origin = "1970-01-01", tz = "UTC")
  rducks_arrow_timestamp_array(values, schema)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_i64_type_class) <- function(type, results, schema) {
  values <- rducks_bigint(rducks_arrow_results_as_character(results))
  rducks_arrow_fixed_width_array(values, schema, 8L, signed = TRUE)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_u64_type_class) <- function(type, results, schema) {
  values <- rducks_ubigint(rducks_arrow_results_as_character(results))
  rducks_arrow_fixed_width_array(values, schema, 8L, signed = FALSE)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_hugeint_type_class) <- function(type, results, schema) {
  values <- rducks_hugeint(rducks_arrow_results_as_character(results))
  rducks_arrow_fixed_width_array(values, schema, 16L, signed = TRUE)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_uhugeint_type_class) <- function(type, results, schema) {
  values <- rducks_uhugeint(rducks_arrow_results_as_character(results))
  rducks_arrow_fixed_width_array(values, schema, 16L, signed = FALSE)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_uuid_type_class) <- function(type, results, schema) {
  values <- rducks_uuid(rducks_arrow_results_as_character(results))
  parsed <- try(nanoarrow::nanoarrow_schema_parse(schema), silent = TRUE)
  if (!inherits(parsed, "try-error") && parsed$type %in% c("fixed_size_binary", "binary")) {
    return(rducks_arrow_uuid_array(values, schema))
  }
  rducks_arrow_string_array(as.character(values), schema)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_interval_type_class) <- function(type, results, schema) {
  rducks_arrow_interval_array(results, schema)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_bit_type_class) <- function(type, results, schema) {
  rducks_arrow_bit_array(results, schema)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_blob_type_class) <- function(type, results, schema) {
  rducks_arrow_binary_payload_array(results, schema)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_geometry_type_class) <- function(type, results, schema) {
  rducks_arrow_binary_payload_array(results, schema)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_variant_type_class) <- function(type, results, schema) {
  storage_results <- lapply(results, function(value) if (is.null(value)) NULL else unclass(value))
  rducks_arrow_values_to_array(rducks_variant_storage_type(), storage_results, schema)
}

S7::method(rducks_arrow_scalar_values_to_array, rducks_scalar_type_class) <- function(type, results, schema) {
  stop("unsupported scalar type for Rducks scalar-UDF nanoarrow output: ", rducks_type_duckdb_sql(type), call. = FALSE)
}

rducks_arrow_map_array <- function(type, results, schema) {
  n <- length(results)
  children <- rducks_type_children(type)
  key_type <- children[[1L]]
  value_type <- children[[2L]]
  entry_schema <- schema$children[[1L]]
  valid <- !vapply(results, is.null, logical(1))
  lengths <- vapply(results, function(x) {
    if (is.null(x)) return(0L)
    if (!is.list(x) || is.null(x$keys) || is.null(x$values)) {
      stop("MAP values must be list(keys = ..., values = ...)", call. = FALSE)
    }
    if (length(x$keys) != length(x$values)) {
      stop("MAP keys and values must have equal length", call. = FALSE)
    }
    length(x$keys)
  }, integer(1))
  offsets <- c(0L, cumsum(lengths))
  flat_keys <- vector("list", sum(lengths))
  flat_values <- vector("list", sum(lengths))
  pos <- 1L
  for (value in results) {
    if (is.null(value)) next
    for (j in seq_len(length(value$keys))) {
      flat_keys[pos] <- list(rducks_arrow_sequence_value_at(key_type, value$keys, j))
      flat_values[pos] <- list(rducks_arrow_sequence_value_at(value_type, value$values, j))
      pos <- pos + 1L
    }
  }
  key_array <- rducks_arrow_values_to_array(key_type, flat_keys, entry_schema$children[[1L]])
  value_array <- rducks_arrow_values_to_array(value_type, flat_values, entry_schema$children[[2L]])
  entry_array <- nanoarrow::nanoarrow_array_init(entry_schema)
  entry_array <- nanoarrow::nanoarrow_array_modify(entry_array, list(
    length = sum(lengths),
    null_count = 0L,
    buffers = list(NULL),
    children = list(key = key_array, value = value_array)
  ))
  array <- nanoarrow::nanoarrow_array_init(schema)
  nanoarrow::nanoarrow_array_modify(array, list(
    length = n,
    null_count = sum(!valid),
    buffers = list(rducks_arrow_validity_buffer(valid), as.integer(offsets)),
    children = list(entries = entry_array)
  ))
}

rducks_arrow_values_to_array <- function(type, results, schema) {
  n <- length(results)
  if (rducks_type_inherits(type, "rducks_scalar_type")) {
    return(rducks_arrow_scalar_values_to_array(type, results, schema))
  }

  if (rducks_type_inherits(type, "rducks_decimal_type")) {
    params <- rducks_type_parameters(type)
    chars <- vapply(results, function(x) {
      if (is.null(x)) NA_character_ else as.character(x)[[1L]]
    }, character(1))
    storage <- rducks_arrow_decimal_storage_strings(chars, params$scale)
    return(rducks_arrow_fixed_width_array(storage, schema, 16L, signed = TRUE))
  }

  if (rducks_type_inherits(type, "rducks_enum_type")) {
    levels <- rducks_type_parameters(type)$levels
    chars <- vapply(results, function(x) if (is.null(x)) NA_character_ else as.character(x)[[1L]], character(1))
    return(rducks_arrow_enum_storage_array(chars, levels, schema))
  }

  if (rducks_type_inherits(type, "rducks_list_type")) {
    child_type <- rducks_type_children(type)[[1L]]
    valid <- !vapply(results, is.null, logical(1))
    lengths <- vapply(results, function(x) if (is.null(x)) 0L else length(x), integer(1))
    offsets <- c(0L, cumsum(lengths))
    flat <- vector("list", sum(lengths))
    pos <- 1L
    for (value in results) {
      if (is.null(value)) next
      for (j in seq_len(length(value))) {
        flat[pos] <- list(rducks_arrow_sequence_value_at(child_type, value, j))
        pos <- pos + 1L
      }
    }
    child_array <- rducks_arrow_values_to_array(child_type, flat, schema$children[[1L]])
    array <- nanoarrow::nanoarrow_array_init(schema)
    return(nanoarrow::nanoarrow_array_modify(array, list(
      length = n,
      null_count = sum(!valid),
      buffers = list(rducks_arrow_validity_buffer(valid), as.integer(offsets)),
      children = list(child_array)
    )))
  }

  if (rducks_type_inherits(type, "rducks_array_type")) {
    child_type <- rducks_type_children(type)[[1L]]
    size <- rducks_type_size(type)
    valid <- !vapply(results, is.null, logical(1))
    flat <- vector("list", n * size)
    pos <- 1L
    for (value in results) {
      if (is.null(value)) {
        pos <- pos + size
        next
      }
      for (j in seq_len(size)) {
        flat[pos] <- list(rducks_arrow_sequence_value_at(child_type, value, j))
        pos <- pos + 1L
      }
    }
    child_array <- rducks_arrow_values_to_array(child_type, flat, schema$children[[1L]])
    array <- nanoarrow::nanoarrow_array_init(schema)
    return(nanoarrow::nanoarrow_array_modify(array, list(
      length = n,
      null_count = sum(!valid),
      buffers = list(rducks_arrow_validity_buffer(valid)),
      children = list(child_array)
    )))
  }

  if (rducks_type_inherits(type, "rducks_struct_type")) {
    children <- rducks_type_children(type)
    child_names <- rducks_type_child_names(type)
    child_arrays <- vector("list", length(children))
    names(child_arrays) <- child_names
    for (i in seq_along(children)) {
      field <- child_names[[i]]
      vals <- lapply(results, function(x) if (is.null(x)) NULL else x[[field]])
      child_arrays[[i]] <- rducks_arrow_values_to_array(children[[i]], vals, schema$children[[i]])
    }
    valid <- !vapply(results, is.null, logical(1))
    array <- nanoarrow::nanoarrow_array_init(schema)
    return(nanoarrow::nanoarrow_array_modify(array, list(
      length = n,
      null_count = sum(!valid),
      buffers = list(rducks_arrow_validity_buffer(valid)),
      children = child_arrays
    )))
  }

  if (rducks_type_inherits(type, "rducks_union_type")) {
    return(rducks_arrow_union_array(type, results, schema))
  }

  if (rducks_type_inherits(type, "rducks_map_type")) {
    return(rducks_arrow_map_array(type, results, schema))
  }
  stop("unsupported Rducks type for scalar-UDF nanoarrow output: ", rducks_type_duckdb_sql(type), call. = FALSE)
}

rducks_arrow_result_array <- function(type, results, output_schema, n) {
  import_schema <- rducks_arrow_import_schema(type, output_schema)
  child_schema <- import_schema$children[[1L]]
  child_array <- rducks_arrow_values_to_array(type, results, child_schema)
  out <- nanoarrow::nanoarrow_array_init(import_schema)
  out <- nanoarrow::nanoarrow_array_modify(
    out,
    list(
      length = as.integer(n),
      null_count = 0L,
      buffers = list(NULL),
      children = list(result = child_array)
    )
  )
  nanoarrow::nanoarrow_array_set_schema(out, import_schema)
  out
}
