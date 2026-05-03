rducks_arrow_error <- function(message) {
  structure(as.character(message)[[1L]], class = "rducks_arrow_error")
}

rducks_arrow_uses_r_null_for_null <- function(type) {
  inherits(type, c(
    "rducks_i64_type", "rducks_u64_type", "rducks_blob_type",
    "rducks_hugeint_type", "rducks_uhugeint_type", "rducks_uuid_type",
    "rducks_interval_type", "rducks_bit_type"
  ))
}

rducks_arrow_validity <- function(array, n = NULL) {
  validity <- as.vector(array$buffers[[1]])
  if (is.null(n)) n <- array$length
  n <- as.integer(n)
  offset <- as.integer(array$offset %||% 0L)
  if (!length(validity)) {
    rep(TRUE, n)
  } else {
    validity[offset + seq_len(n)]
  }
}

rducks_arrow_pack_bits <- function(values) {
  .Call(RDUCKS_arrow_pack_bits, values)
}

rducks_arrow_validity_buffer <- function(valid) {
  valid <- as.logical(valid)
  if (all(valid)) {
    return(NULL)
  }
  rducks_arrow_pack_bits(valid)
}

rducks_arrow_decimal_unscale_strings <- function(x, scale) {
  .Call(RDUCKS_decimal_unscale_strings, x, as.integer(scale))
}

rducks_arrow_decimal_array_to_values <- function(array, width, scale) {
  n <- as.integer(array$length)
  data <- as.raw(array$buffers[[2L]])
  if (n == 0L) {
    return(rducks_decimal(character(), width, scale))
  }
  storage_width <- length(data) / n
  if (!is.finite(storage_width) || storage_width != as.integer(storage_width) ||
    !as.integer(storage_width) %in% c(2L, 4L, 8L, 16L, 32L)) {
    stop("unsupported Arrow DECIMAL storage width: ", storage_width, call. = FALSE)
  }
  storage <- rducks_arrow_fixed_width_array_to_decimal(array, as.integer(storage_width), signed = TRUE)
  rducks_decimal(rducks_arrow_decimal_unscale_strings(storage, scale), width, scale)
}

rducks_arrow_decimal_storage_strings <- function(x, scale) {
  .Call(RDUCKS_decimal_storage_strings, x, as.integer(scale))
}

rducks_arrow_add_decimal_string_small <- function(x, addend) {
  .Call(RDUCKS_decimal_string_add_small, x, as.integer(addend))
}

rducks_arrow_multiply_decimal_string_small <- function(x, multiplier) {
  .Call(RDUCKS_decimal_string_multiply_small, x, as.integer(multiplier))
}

rducks_arrow_decimal_string_from_unsigned_bytes <- function(bytes) {
  .Call(RDUCKS_decimal_string_from_unsigned_bytes, bytes)
}

rducks_arrow_decimal_string_from_twos_complement <- function(bytes, signed = TRUE) {
  bytes <- as.raw(bytes)
  .Call(
    RDUCKS_decimal_strings_from_fixed_width_bytes,
    bytes, TRUE, 0L, 1L, length(bytes), isTRUE(signed)
  )[[1L]]
}

rducks_arrow_fixed_width_array_to_decimal <- function(array, width, signed = TRUE) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  bytes <- as.raw(array$buffers[[2L]])
  .Call(RDUCKS_decimal_strings_from_fixed_width_bytes, bytes, valid, offset, n, as.integer(width), isTRUE(signed))
}

rducks_arrow_fixed_width_array <- function(values, schema, width, signed = TRUE) {
  values <- as.character(values)
  valid <- !is.na(values)
  data <- .Call(RDUCKS_fixed_width_bytes_from_decimal_strings, values, as.integer(width), isTRUE(signed))
  array <- nanoarrow::nanoarrow_array_init(schema)
  nanoarrow::nanoarrow_array_modify(
    array,
    list(
      length = length(values),
      null_count = sum(!valid),
      buffers = list(rducks_arrow_validity_buffer(valid), data)
    )
  )
}

rducks_arrow_interval_array_to_values <- function(array) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  bytes <- as.raw(array$buffers[[2L]])
  values <- .Call(RDUCKS_interval_values_from_bytes, bytes, valid, offset, n)
  rducks_interval(values$months, values$days, values$micros)
}

rducks_arrow_uuid_array_to_character <- function(array) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  # Fixed-size binary arrays do not have a validity-only first buffer when
  # accessed through nanoarrow; account for both fixed-size-binary and binary
  # proxy shapes.
  data_buffer_index <- if (length(array$buffers) >= 2L) 2L else 1L
  bytes <- as.raw(array$buffers[[data_buffer_index]])
  .Call(RDUCKS_uuid_strings_from_bytes, bytes, valid, offset, n)
}

rducks_arrow_uuid_array <- function(values, schema) {
  values <- as.character(values)
  valid <- !is.na(values)
  data <- .Call(RDUCKS_uuid_bytes_from_strings, values)
  array <- nanoarrow::nanoarrow_array_init(schema)
  nanoarrow::nanoarrow_array_modify(
    array,
    list(
      length = length(values),
      null_count = sum(!valid),
      buffers = list(rducks_arrow_validity_buffer(valid), data)
    )
  )
}

rducks_arrow_interval_array <- function(values, schema) {
  encoded <- .Call(RDUCKS_interval_bytes_from_values, values)
  array <- nanoarrow::nanoarrow_array_init(schema)
  nanoarrow::nanoarrow_array_modify(
    array,
    list(
      length = length(values),
      null_count = sum(!encoded$valid),
      buffers = list(rducks_arrow_validity_buffer(encoded$valid), encoded$data)
    )
  )
}

rducks_arrow_schema_extension_name <- function(schema) {
  parsed <- try(nanoarrow::nanoarrow_schema_parse(schema), silent = TRUE)
  if (inherits(parsed, "try-error")) return(NULL)
  parsed$extension_name %||% NULL
}

rducks_arrow_bool8_array_to_logical <- function(array) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  bytes <- as.raw(array$buffers[[2L]])
  .Call(RDUCKS_arrow_bool_to_logical, bytes, valid, offset, n, TRUE)
}

rducks_arrow_bool8_array <- function(values, schema) {
  values <- as.logical(values)
  valid <- !is.na(values)
  data <- as.raw(ifelse(is.na(values) | !values, 0L, 1L))
  array <- nanoarrow::nanoarrow_array_init(schema)
  nanoarrow::nanoarrow_array_modify(
    array,
    list(
      length = length(values),
      null_count = sum(!valid),
      buffers = list(rducks_arrow_validity_buffer(valid), data)
    )
  )
}

rducks_arrow_bool_array_to_logical <- function(array) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  bytes <- as.raw(array$buffers[[2L]])
  .Call(RDUCKS_arrow_bool_to_logical, bytes, valid, offset, n, FALSE)
}

rducks_arrow_bool_array <- function(values, schema) {
  if (identical(rducks_arrow_schema_extension_name(schema), "arrow.bool8")) {
    return(rducks_arrow_bool8_array(values, schema))
  }
  values <- as.logical(values)
  valid <- !is.na(values)
  data <- rducks_arrow_pack_bits(!is.na(values) & values)
  array <- nanoarrow::nanoarrow_array_init(schema)
  nanoarrow::nanoarrow_array_modify(
    array,
    list(
      length = length(values),
      null_count = sum(!valid),
      buffers = list(rducks_arrow_validity_buffer(valid), data)
    )
  )
}

rducks_arrow_float_array <- function(values, schema, width) {
  values <- as.numeric(values)
  valid <- !(is.na(values) & !is.nan(values))
  data_values <- values
  data_values[!valid] <- 0
  data <- writeBin(data_values, raw(), size = width, endian = "little")
  array <- nanoarrow::nanoarrow_array_init(schema)
  nanoarrow::nanoarrow_array_modify(
    array,
    list(
      length = length(values),
      null_count = sum(!valid),
      buffers = list(rducks_arrow_validity_buffer(valid), data)
    )
  )
}

rducks_arrow_time_array <- function(values, schema) {
  values <- as.numeric(values)
  valid <- !is.na(values)
  micros <- round(values * 1000000)
  data <- .Call(RDUCKS_arrow_i64_storage_from_numeric, micros)
  array <- nanoarrow::nanoarrow_array_init(schema)
  nanoarrow::nanoarrow_array_modify(
    array,
    list(
      length = length(values),
      null_count = sum(!valid),
      buffers = list(rducks_arrow_validity_buffer(valid), data)
    )
  )
}

rducks_arrow_timestamp_array <- function(values, schema) {
  rducks_arrow_time_array(values, schema)
}

rducks_arrow_string_array_to_character <- function(array) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  offsets <- as.integer(as.vector(array$buffers[[2L]]))
  data <- as.raw(array$buffers[[3L]])
  .Call(RDUCKS_arrow_string_array_to_character, data, offsets, valid, offset, n)
}

rducks_arrow_string_array <- function(values, schema) {
  encoded <- .Call(RDUCKS_arrow_string_array_from_character, values)
  array <- nanoarrow::nanoarrow_array_init(schema)
  nanoarrow::nanoarrow_array_modify(
    array,
    list(
      length = length(values),
      null_count = sum(!encoded$valid),
      buffers = list(rducks_arrow_validity_buffer(encoded$valid), encoded$offsets, encoded$data)
    )
  )
}

rducks_arrow_binary_array_to_values <- function(array) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  offsets <- as.integer(as.vector(array$buffers[[2L]]))
  data <- as.raw(array$buffers[[3L]])
  .Call(RDUCKS_arrow_binary_array_to_values, data, offsets, valid, offset, n)
}

rducks_arrow_binary_payload_array <- function(payloads, schema) {
  encoded <- .Call(RDUCKS_arrow_binary_payload_array, payloads)
  array <- nanoarrow::nanoarrow_array_init(schema)
  nanoarrow::nanoarrow_array_modify(
    array,
    list(
      length = length(payloads),
      null_count = sum(!encoded$valid),
      buffers = list(rducks_arrow_validity_buffer(encoded$valid), encoded$offsets, encoded$data)
    )
  )
}

rducks_arrow_bit_array_to_values <- function(array) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  offsets <- as.integer(as.vector(array$buffers[[2L]]))
  data <- as.raw(array$buffers[[3L]])
  .Call(RDUCKS_bit_payloads_to_values, data, offsets, valid, offset, n)
}

rducks_arrow_bit_array <- function(values, schema) {
  encoded <- .Call(RDUCKS_bit_values_to_payloads, values)
  array <- nanoarrow::nanoarrow_array_init(schema)
  nanoarrow::nanoarrow_array_modify(
    array,
    list(
      length = length(values),
      null_count = sum(!encoded$valid),
      buffers = list(rducks_arrow_validity_buffer(encoded$valid), encoded$offsets, encoded$data)
    )
  )
}

rducks_arrow_enum_storage_schema <- function(schema) {
  out <- nanoarrow::as_nanoarrow_schema(schema)
  out$dictionary <- NULL
  out
}

rducks_arrow_enum_index_width <- function(schema) {
  parsed <- try(nanoarrow::nanoarrow_schema_parse(schema), silent = TRUE)
  storage_type <- if (inherits(parsed, "try-error")) NULL else parsed$storage_type %||% parsed$type
  switch(
    storage_type,
    int8 = 1L, uint8 = 1L,
    int16 = 2L, uint16 = 2L,
    int32 = 4L, uint32 = 4L,
    int64 = 8L, uint64 = 8L,
    1L
  )
}

rducks_arrow_enum_array_to_values <- function(array, schema, levels) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  bytes <- as.raw(array$buffers[[2L]])
  width <- rducks_arrow_enum_index_width(schema)
  out <- rep(NA_character_, n)
  for (i in seq_len(n)) {
    if (!isTRUE(valid[[i]])) next
    start <- (offset + i - 1L) * width + 1L
    idx <- 0
    multiplier <- 1
    for (byte in bytes[start + seq_len(width) - 1L]) {
      idx <- idx + as.integer(byte) * multiplier
      multiplier <- multiplier * 256
    }
    if (idx < 0L || idx >= length(levels)) {
      stop("enum index is outside declared levels", call. = FALSE)
    }
    out[[i]] <- levels[[idx + 1L]]
  }
  rducks_enum(out, levels = levels)
}

rducks_arrow_enum_storage_array <- function(chars, levels, schema) {
  storage_schema <- rducks_arrow_enum_storage_schema(schema)
  valid <- !is.na(chars)
  idx <- match(chars, levels) - 1L
  idx[!valid] <- 0L
  if (any(is.na(idx) & valid)) stop("enum values must be present in levels", call. = FALSE)
  width <- rducks_arrow_enum_index_width(schema)
  data <- raw(length(chars) * width)
  for (i in seq_along(chars)) {
    value <- as.integer(idx[[i]])
    start <- (i - 1L) * width + 1L
    for (byte_index in seq_len(width)) {
      data[[start + byte_index - 1L]] <- as.raw(value %% 256L)
      value <- value %/% 256L
    }
  }
  array <- nanoarrow::nanoarrow_array_init(storage_schema)
  nanoarrow::nanoarrow_array_modify(array, list(
    length = length(chars),
    null_count = sum(!valid),
    buffers = list(rducks_arrow_validity_buffer(valid), data)
  ))
}

rducks_arrow_map_array_to_values <- function(type, array, schema = NULL) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  offsets <- as.integer(as.vector(array$buffers[[2L]]))
  entries <- array$children[[1L]]
  entry_schema <- if (is.null(schema)) NULL else schema$children[[1L]]
  key_type <- rducks_type_children(type)[[1L]]
  value_type <- rducks_type_children(type)[[2L]]
  keys <- rducks_arrow_array_to_values(key_type, entries$children[[1L]], if (is.null(entry_schema)) NULL else entry_schema$children[[1L]])
  values <- rducks_arrow_array_to_values(value_type, entries$children[[2L]], if (is.null(entry_schema)) NULL else entry_schema$children[[2L]])
  out <- vector("list", n)
  for (i in seq_len(n)) {
    if (!isTRUE(valid[[i]])) next
    start <- offsets[[offset + i]] + 1L
    end <- offsets[[offset + i + 1L]]
    rows <- if (end >= start) start:end else integer()
    out[[i]] <- list(keys = keys[rows], values = values[rows])
  }
  out
}

rducks_arrow_union_array_to_values <- function(type, array, schema = NULL) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  type_ids <- as.integer(as.vector(array$buffers[[1L]]))
  children <- rducks_type_children(type)
  child_names <- rducks_type_child_names(type)
  child_values <- vector("list", length(children))
  child_nulls <- vector("list", length(children))
  for (j in seq_along(children)) {
    child_schema <- if (is.null(schema)) NULL else schema$children[[j]]
    child_values[[j]] <- rducks_arrow_array_to_values(children[[j]], array$children[[j]], child_schema)
    child_nulls[[j]] <- !rducks_arrow_validity(array$children[[j]], n)
  }
  out <- vector("list", n)
  for (i in seq_len(n)) {
    tag_index <- type_ids[[offset + i]] + 1L
    if (tag_index < 1L || tag_index > length(children)) stop("invalid nanoarrow UNION tag", call. = FALSE)
    value <- rducks_arrow_value_at(children[[tag_index]], child_values[[tag_index]], child_nulls[[tag_index]], i)
    out[[i]] <- rducks_union(child_names[[tag_index]], value)
  }
  structure(out, class = "rducks_union_list")
}

rducks_arrow_union_array <- function(type, results, schema) {
  n <- length(results)
  children <- rducks_type_children(type)
  child_names <- rducks_type_child_names(type)
  type_ids <- integer(n)
  child_results <- replicate(length(children), vector("list", n), simplify = FALSE)
  for (i in seq_along(results)) {
    value <- results[[i]]
    if (is.null(value)) {
      type_ids[[i]] <- 0L
      next
    }
    if (!inherits(value, "rducks_union")) value <- rducks_union(value$tag, value$value)
    tag_index <- match(value$tag, child_names)
    if (is.na(tag_index)) stop("union tag must be one of: ", paste(child_names, collapse = ", "), call. = FALSE)
    type_ids[[i]] <- tag_index - 1L
    child_results[[tag_index]][i] <- list(value$value)
  }
  child_arrays <- vector("list", length(children))
  names(child_arrays) <- child_names
  for (j in seq_along(children)) {
    child_arrays[[j]] <- rducks_arrow_values_to_array(children[[j]], child_results[[j]], schema$children[[j]])
  }
  array <- nanoarrow::nanoarrow_array_init(schema)
  nanoarrow::nanoarrow_array_modify(
    array,
    list(
      length = n,
      null_count = 0L,
      buffers = list(as.raw(type_ids)),
      children = child_arrays
    )
  )
}

rducks_arrow_sequence_slice <- function(type, values, rows) {
  if (!length(rows)) {
    return(values[integer()])
  }
  if (inherits(type, "rducks_scalar_type") || inherits(type, c("rducks_decimal_type", "rducks_enum_type", "rducks_interval_type"))) {
    return(values[rows])
  }
  values[rows]
}

rducks_arrow_list_array_to_values <- function(type, array, schema = NULL) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  offsets <- as.integer(as.vector(array$buffers[[2L]]))
  child_type <- rducks_type_children(type)[[1L]]
  child_schema <- if (is.null(schema)) NULL else schema$children[[1L]]
  child_values <- rducks_arrow_array_to_values(child_type, array$children[[1L]], child_schema)
  out <- vector("list", n)
  for (i in seq_len(n)) {
    if (!isTRUE(valid[[i]])) next
    start <- offsets[[offset + i]] + 1L
    end <- offsets[[offset + i + 1L]]
    rows <- if (end >= start) start:end else integer()
    out[[i]] <- rducks_arrow_sequence_slice(child_type, child_values, rows)
  }
  out
}

rducks_arrow_array_array_to_values <- function(type, array, schema = NULL) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  size <- as.integer(rducks_type_size(type))
  child_type <- rducks_type_children(type)[[1L]]
  child_schema <- if (is.null(schema)) NULL else schema$children[[1L]]
  child_values <- rducks_arrow_array_to_values(child_type, array$children[[1L]], child_schema)
  out <- vector("list", n)
  for (i in seq_len(n)) {
    if (!isTRUE(valid[[i]])) next
    start <- (offset + i - 1L) * size + 1L
    rows <- start + seq_len(size) - 1L
    out[[i]] <- rducks_arrow_sequence_slice(child_type, child_values, rows)
  }
  out
}

rducks_arrow_struct_array_to_values <- function(type, array, schema = NULL) {
  n <- as.integer(array$length)
  valid <- rducks_arrow_validity(array, n)
  children <- rducks_type_children(type)
  child_names <- rducks_type_child_names(type)
  child_values <- vector("list", length(children))
  child_nulls <- vector("list", length(children))
  for (j in seq_along(children)) {
    child_schema <- if (is.null(schema)) NULL else schema$children[[j]]
    child_values[[j]] <- rducks_arrow_array_to_values(children[[j]], array$children[[j]], child_schema)
    child_nulls[[j]] <- if (inherits(children[[j]], "rducks_union_type")) rep(FALSE, n) else !rducks_arrow_validity(array$children[[j]], n)
  }
  out <- vector("list", n)
  for (i in seq_len(n)) {
    if (!isTRUE(valid[[i]])) next
    row <- vector("list", length(children))
    names(row) <- child_names
    for (j in seq_along(children)) {
      row[j] <- list(rducks_arrow_value_at(children[[j]], child_values[[j]], child_nulls[[j]], i))
    }
    out[[i]] <- row
  }
  out
}

rducks_arrow_import_child_schema <- function(type, schema) {
  out <- nanoarrow::as_nanoarrow_schema(schema)
  if (inherits(type, "rducks_enum_type")) {
    return(rducks_arrow_enum_storage_schema(out))
  }
  if (inherits(type, c("rducks_list_type", "rducks_array_type"))) {
    out$children[[1L]] <- rducks_arrow_import_child_schema(rducks_type_children(type)[[1L]], out$children[[1L]])
    return(out)
  }
  if (inherits(type, "rducks_struct_type")) {
    children <- rducks_type_children(type)
    for (i in seq_along(children)) {
      out$children[[i]] <- rducks_arrow_import_child_schema(children[[i]], out$children[[i]])
    }
    return(out)
  }
  if (inherits(type, "rducks_map_type")) {
    children <- rducks_type_children(type)
    entries <- out$children[[1L]]
    entries$children[[1L]] <- rducks_arrow_import_child_schema(children[[1L]], entries$children[[1L]])
    entries$children[[2L]] <- rducks_arrow_import_child_schema(children[[2L]], entries$children[[2L]])
    out$children[[1L]] <- entries
    return(out)
  }
  if (inherits(type, "rducks_union_type")) {
    children <- rducks_type_children(type)
    for (i in seq_along(children)) {
      out$children[[i]] <- rducks_arrow_import_child_schema(children[[i]], out$children[[i]])
    }
    return(out)
  }
  out
}

rducks_arrow_import_schema <- function(type, output_schema) {
  schema <- nanoarrow::as_nanoarrow_schema(output_schema)
  schema$children[[1L]] <- rducks_arrow_import_child_schema(type, schema$children[[1L]])
  schema
}

rducks_arrow_scalar_array_to_values <- S7::new_generic(
  "rducks_arrow_scalar_array_to_values",
  "type",
  function(type, array, schema = NULL) S7::S7_dispatch()
)

S7::method(rducks_arrow_scalar_array_to_values, rducks_bool_type_class) <- function(type, array, schema = NULL) {
  if (identical(rducks_arrow_schema_extension_name(schema), "arrow.bool8")) {
    rducks_arrow_bool8_array_to_logical(array)
  } else {
    rducks_arrow_bool_array_to_logical(array)
  }
}

rducks_arrow_integer_storage_array_to_values <- function(array, width, signed = TRUE, numeric = FALSE) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  bytes <- as.raw(array$buffers[[2L]])
  .Call(RDUCKS_arrow_integer_storage_to_values, bytes, valid, offset, n, as.integer(width), isTRUE(signed), isTRUE(numeric))
}

rducks_arrow_integer_storage_array <- function(values, schema, width, signed = TRUE) {
  values <- as.numeric(values)
  valid <- !is.na(values)
  data <- .Call(RDUCKS_arrow_integer_storage_from_values, values, as.integer(width), isTRUE(signed))
  array <- nanoarrow::nanoarrow_array_init(schema)
  nanoarrow::nanoarrow_array_modify(array, list(
    length = length(values),
    null_count = sum(!valid),
    buffers = list(rducks_arrow_validity_buffer(valid), data)
  ))
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_i8_type_class) <- function(type, array, schema = NULL) {
  rducks_arrow_integer_storage_array_to_values(array, 1L, signed = TRUE)
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_u8_type_class) <- function(type, array, schema = NULL) {
  rducks_arrow_integer_storage_array_to_values(array, 1L, signed = FALSE)
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_i16_type_class) <- function(type, array, schema = NULL) {
  rducks_arrow_integer_storage_array_to_values(array, 2L, signed = TRUE)
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_u16_type_class) <- function(type, array, schema = NULL) {
  rducks_arrow_integer_storage_array_to_values(array, 2L, signed = FALSE)
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_i32_type_class) <- function(type, array, schema = NULL) {
  rducks_arrow_integer_storage_array_to_values(array, 4L, signed = TRUE)
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_r_integer_scalar_type_class) <- function(type, array, schema = NULL) {
  rducks_arrow_integer_storage_array_to_values(array, 4L, signed = TRUE)
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_u32_type_class) <- function(type, array, schema = NULL) {
  rducks_arrow_integer_storage_array_to_values(array, 4L, signed = FALSE, numeric = TRUE)
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_i64_type_class) <- function(type, array, schema = NULL) {
  rducks_bigint(rducks_arrow_fixed_width_array_to_decimal(array, 8L, signed = TRUE))
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_u64_type_class) <- function(type, array, schema = NULL) {
  rducks_ubigint(rducks_arrow_fixed_width_array_to_decimal(array, 8L, signed = FALSE))
}

rducks_arrow_float_array_to_values <- function(array, width) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  data <- as.raw(array$buffers[[2L]])
  if (!n) return(numeric())
  start <- offset * width + 1L
  bytes <- data[start + seq_len(n * width) - 1L]
  out <- readBin(bytes, numeric(), n = n, size = width, endian = "little")
  out[!valid] <- NA_real_
  out
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_floating_scalar_type_class) <- function(type, array, schema = NULL) {
  width <- if (inherits(type, "rducks_f32_type")) 4L else 8L
  rducks_arrow_float_array_to_values(array, width)
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_varchar_type_class) <- function(type, array, schema = NULL) {
  rducks_arrow_string_array_to_character(array)
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_blob_type_class) <- function(type, array, schema = NULL) {
  rducks_arrow_binary_array_to_values(array)
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_date_type_class) <- function(type, array, schema = NULL) {
  days <- rducks_arrow_integer_storage_array_to_values(array, 4L, signed = TRUE)
  as.Date(days, origin = "1970-01-01")
}

rducks_arrow_time_array_to_values <- function(array) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  bytes <- as.raw(array$buffers[[2L]])
  .Call(RDUCKS_arrow_i64_micros_to_seconds, bytes, valid, offset, n)
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_time_type_class) <- function(type, array, schema = NULL) {
  rducks_arrow_time_array_to_values(array)
}

rducks_arrow_timestamp_array_to_values <- function(array) {
  seconds <- rducks_arrow_time_array_to_values(array)
  as.POSIXct(seconds, origin = "1970-01-01", tz = "UTC")
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_timestamp_type_class) <- function(type, array, schema = NULL) {
  rducks_arrow_timestamp_array_to_values(array)
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_hugeint_type_class) <- function(type, array, schema = NULL) {
  rducks_hugeint(rducks_arrow_fixed_width_array_to_decimal(array, 16L, signed = TRUE))
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_uhugeint_type_class) <- function(type, array, schema = NULL) {
  rducks_uhugeint(rducks_arrow_fixed_width_array_to_decimal(array, 16L, signed = FALSE))
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_uuid_type_class) <- function(type, array, schema = NULL) {
  if (identical(rducks_arrow_schema_extension_name(schema), "arrow.uuid")) {
    rducks_uuid(rducks_arrow_uuid_array_to_character(array))
  } else {
    rducks_uuid(rducks_arrow_string_array_to_character(array))
  }
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_interval_type_class) <- function(type, array, schema = NULL) {
  rducks_arrow_interval_array_to_values(array)
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_bit_type_class) <- function(type, array, schema = NULL) {
  rducks_arrow_bit_array_to_values(array)
}

S7::method(rducks_arrow_scalar_array_to_values, rducks_scalar_type_class) <- function(type, array, schema = NULL) {
  stop("unsupported scalar type for Rducks scalar-mode nanoarrow input: ", rducks_type_duckdb_sql(type), call. = FALSE)
}

rducks_arrow_array_to_values <- function(type, array, schema = NULL) {
  if (inherits(type, "rducks_scalar_type")) {
    return(rducks_arrow_scalar_array_to_values(type, array, schema))
  }
  if (inherits(type, "rducks_decimal_type")) {
    params <- rducks_type_parameters(type)
    return(rducks_arrow_decimal_array_to_values(array, params$width, params$scale))
  }
  if (inherits(type, "rducks_enum_type")) {
    levels <- rducks_type_parameters(type)$levels
    return(rducks_arrow_enum_array_to_values(array, schema, levels))
  }
  if (inherits(type, "rducks_list_type")) {
    return(rducks_arrow_list_array_to_values(type, array, schema))
  }
  if (inherits(type, "rducks_array_type")) {
    return(rducks_arrow_array_array_to_values(type, array, schema))
  }
  if (inherits(type, "rducks_struct_type")) {
    return(rducks_arrow_struct_array_to_values(type, array, schema))
  }
  if (inherits(type, "rducks_map_type")) {
    return(rducks_arrow_map_array_to_values(type, array, schema))
  }
  if (inherits(type, "rducks_union_type")) {
    return(rducks_arrow_union_array_to_values(type, array, schema))
  }
  stop("unsupported Rducks type for scalar-mode nanoarrow input: ", rducks_type_duckdb_sql(type), call. = FALSE)
}

rducks_arrow_value_at <- function(type, values, nulls, i) {
  if (isTRUE(nulls[[i]])) {
    if (rducks_arrow_uses_r_null_for_null(type) || !inherits(type, "rducks_scalar_type")) {
      return(NULL)
    }
  }
  if (inherits(type, "rducks_scalar_type")) {
    if (inherits(type, c("rducks_blob_type", "rducks_bit_type"))) return(values[[i]])
    return(values[i])
  }
  if (inherits(type, c("rducks_decimal_type", "rducks_enum_type", "rducks_interval_type"))) {
    return(values[i])
  }
  if (inherits(type, "rducks_struct_type") && is.data.frame(values)) {
    row <- as.list(values[i, , drop = FALSE])
    children <- rducks_type_children(type)
    child_names <- rducks_type_child_names(type)
    for (field_index in seq_along(child_names)) {
      field <- child_names[[field_index]]
      child <- children[[field_index]]
      if ((!inherits(child, "rducks_scalar_type") || inherits(child, c("rducks_blob_type", "rducks_bit_type"))) &&
          is.list(row[[field]]) && length(row[[field]]) == 1L) {
        row[[field]] <- row[[field]][[1L]]
      }
    }
    return(row)
  }
  if (inherits(type, "rducks_map_type")) {
    value <- values[[i]]
    if (is.data.frame(value)) {
      nms <- names(value)
      key_name <- if ("key" %in% nms) "key" else nms[[1L]]
      value_name <- if ("value" %in% nms) "value" else nms[[2L]]
      return(list(keys = value[[key_name]], values = value[[value_name]]))
    }
    return(value)
  }
  if (inherits(type, "rducks_union_type")) {
    value <- values[[i]]
    if (inherits(value, "rducks_union")) return(value)
    if (is.list(value) && !is.null(value$tag) && !is.null(value$value)) return(rducks_union(value$tag, value$value))
    return(value)
  }
  values[[i]]
}

rducks_arrow_results_as_logical <- function(results) {
  vapply(results, function(x) if (is.null(x)) NA else as.logical(x)[[1L]], logical(1))
}

rducks_arrow_results_as_integer <- function(results) {
  vapply(results, function(x) if (is.null(x)) NA_integer_ else as.integer(x)[[1L]], integer(1))
}

rducks_arrow_results_as_numeric <- function(results) {
  vapply(results, function(x) if (is.null(x)) NA_real_ else as.numeric(x)[[1L]], numeric(1))
}

rducks_arrow_results_as_character <- function(results) {
  vapply(results, function(x) if (is.null(x)) NA_character_ else as.character(x)[[1L]], character(1))
}

rducks_scalar_udf_return_needs_length_one <- function(type) {
  if (inherits(type, c("rducks_decimal_type", "rducks_enum_type"))) {
    return(TRUE)
  }
  inherits(type, "rducks_scalar_type") && !inherits(type, c("rducks_blob_type", "rducks_bit_type"))
}

rducks_normalize_scalar_udf_return <- function(type, value) {
  if (inherits(type, "rducks_decimal_type") && inherits(value, "rducks_decimal")) {
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
  if (inherits(type, "rducks_scalar_type")) {
    if (inherits(type, c("rducks_blob_type", "rducks_bit_type"))) return(value[[j]])
    return(value[j])
  }
  if (inherits(type, c("rducks_decimal_type", "rducks_enum_type", "rducks_interval_type"))) {
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

S7::method(rducks_arrow_scalar_values_to_array, rducks_scalar_type_class) <- function(type, results, schema) {
  stop("unsupported scalar type for Rducks scalar-mode nanoarrow output: ", rducks_type_duckdb_sql(type), call. = FALSE)
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
  if (inherits(type, "rducks_scalar_type")) {
    return(rducks_arrow_scalar_values_to_array(type, results, schema))
  }

  if (inherits(type, "rducks_decimal_type")) {
    params <- rducks_type_parameters(type)
    chars <- vapply(results, function(x) {
      if (is.null(x)) NA_character_ else as.character(x)[[1L]]
    }, character(1))
    storage <- rducks_arrow_decimal_storage_strings(chars, params$scale)
    return(rducks_arrow_fixed_width_array(storage, schema, 16L, signed = TRUE))
  }

  if (inherits(type, "rducks_enum_type")) {
    levels <- rducks_type_parameters(type)$levels
    chars <- vapply(results, function(x) if (is.null(x)) NA_character_ else as.character(x)[[1L]], character(1))
    return(rducks_arrow_enum_storage_array(chars, levels, schema))
  }

  if (inherits(type, "rducks_list_type")) {
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

  if (inherits(type, "rducks_array_type")) {
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

  if (inherits(type, "rducks_struct_type")) {
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

  if (inherits(type, "rducks_union_type")) {
    return(rducks_arrow_union_array(type, results, schema))
  }

  if (inherits(type, "rducks_map_type")) {
    return(rducks_arrow_map_array(type, results, schema))
  }
  stop("unsupported Rducks type for scalar-mode nanoarrow output: ", rducks_type_duckdb_sql(type), call. = FALSE)
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

rducks_arrow_ipc_encode <- function(data) {
  con <- rawConnection(raw(), open = "wb")
  on.exit(close(con), add = TRUE)
  nanoarrow::write_nanoarrow(data, con)
  rawConnectionValue(con)
}

rducks_arrow_ipc_decode_stream <- function(payload, lazy = FALSE) {
  nanoarrow::read_nanoarrow(as.raw(payload), lazy = lazy)
}

rducks_scalar_prepare_inputs <- function(arg_types, input_array, input_schema, n) {
  n <- as.integer(n)
  if (!nanoarrow::nanoarrow_pointer_is_valid(input_array)) {
    stop("input nanoarrow array pointer is not valid", call. = FALSE)
  }
  if (!nanoarrow::nanoarrow_pointer_is_valid(input_schema)) {
    stop("input nanoarrow schema pointer is not valid", call. = FALSE)
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

rducks_scalar_args_at <- function(arg_types, prepared, row) {
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

rducks_vectorized_column_values <- function(type, values, nulls, rows) {
  if (!length(rows)) {
    return(values[integer()])
  }
  if (any(nulls[rows]) && (rducks_arrow_uses_r_null_for_null(type) || !inherits(type, "rducks_scalar_type"))) {
    return(lapply(rows, function(i) rducks_arrow_value_at(type, values, nulls, i)))
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
  if (inherits(type, "rducks_struct_type") && is.data.frame(value)) {
    return(nrow(value))
  }
  length(value)
}

rducks_vectorized_return_value_at <- function(type, value, i) {
  if (inherits(type, "rducks_struct_type") && is.data.frame(value)) {
    row <- as.list(value[i, , drop = FALSE])
    children <- rducks_type_children(type)
    child_names <- rducks_type_child_names(type)
    for (field_index in seq_along(child_names)) {
      field <- child_names[[field_index]]
      child <- children[[field_index]]
      if ((!inherits(child, "rducks_scalar_type") || inherits(child, c("rducks_blob_type", "rducks_bit_type"))) &&
          is.list(row[[field]]) && length(row[[field]]) == 1L) {
        row[[field]] <- row[[field]][[1L]]
      }
    }
    return(row)
  }
  if (is.list(value) && !is.data.frame(value) && !inherits(value, c("rducks_decimal", "rducks_interval", "rducks_bits"))) {
    return(value[[i]])
  }
  if (inherits(type, "rducks_scalar_type") && !inherits(type, c("rducks_blob_type", "rducks_bit_type"))) {
    return(value[i])
  }
  if (inherits(type, c("rducks_decimal_type", "rducks_enum_type", "rducks_interval_type"))) {
    return(value[i])
  }
  value[[i]]
}

rducks_vectorized_result_to_rows <- function(return_type, value, n) {
  n <- as.integer(n)
  if (is.null(value)) {
    return(vector("list", n))
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
        return(structure(list(n = n), class = "rducks_arrow_return_null"))
      }
      stop(e)
    }
  )
}

rducks_vectorized_eval_prepared_chunk <- function(fun, arg_types, return_type, prepared,
                                                  null_handling, exception_handling) {
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
  rows <- if (inherits(value, "rducks_arrow_return_null")) {
    vector("list", length(eval_rows))
  } else {
    rducks_vectorized_result_to_rows(return_type, value, length(eval_rows))
  }
  results[eval_rows] <- rows
  results
}

rducks_scalar_results_to_arrow <- function(return_type, results, output_schema, n) {
  rducks_arrow_result_array(return_type, results, output_schema, n)
}

rducks_make_scalar_engine <- function(fun, spec, null_handling, exception_handling,
                                      plan = rducks_scalar_execution_plan()) {
  force(fun)
  force(spec)
  force(null_handling)
  force(exception_handling)
  force(plan)
  list(
    fun = fun,
    arg_types = spec$arg_types,
    return_type = spec$return_type,
    null_handling = null_handling,
    exception_handling = exception_handling,
    plan = plan,
    prepare_inputs = rducks_scalar_prepare_inputs,
    eval_rows = rducks_scalar_eval_prepared_rows,
    results_to_arrow = rducks_scalar_results_to_arrow,
    serialization = if (identical(plan$serialization, "arrow_ipc")) list(
      kind = "arrow_ipc",
      encode = rducks_arrow_ipc_encode,
      decode_stream = rducks_arrow_ipc_decode_stream
    ) else NULL
  )
}

rducks_make_vectorized_engine <- function(fun, spec, null_handling, exception_handling,
                                          plan = rducks_scalar_execution_plan()) {
  force(fun)
  force(spec)
  force(null_handling)
  force(exception_handling)
  force(plan)
  list(
    fun = fun,
    arg_types = spec$arg_types,
    return_type = spec$return_type,
    null_handling = null_handling,
    exception_handling = exception_handling,
    plan = plan,
    prepare_inputs = rducks_scalar_prepare_inputs,
    eval_rows = rducks_vectorized_eval_prepared_chunk,
    results_to_arrow = rducks_scalar_results_to_arrow,
    serialization = if (identical(plan$serialization, "arrow_ipc")) list(
      kind = "arrow_ipc",
      encode = rducks_arrow_ipc_encode,
      decode_stream = rducks_arrow_ipc_decode_stream
    ) else NULL
  )
}

rducks_scalar_evaluate_arrow_chunk <- function(engine, input_array, input_schema, output_schema, n) {
  tryCatch({
    n <- as.integer(n)
    if (!nanoarrow::nanoarrow_pointer_is_valid(output_schema)) {
      stop("output nanoarrow schema pointer is not valid", call. = FALSE)
    }
    prepared <- engine$prepare_inputs(engine$arg_types, input_array, input_schema, n)
    results <- engine$eval_rows(
      engine$fun,
      engine$arg_types,
      engine$return_type,
      prepared,
      engine$null_handling,
      engine$exception_handling
    )
    engine$results_to_arrow(engine$return_type, results, output_schema, n)
  }, error = function(e) {
    msg <- paste0("Rducks nanoarrow R function or marshal error: ", conditionMessage(e))
    .rducks_state$last_arrow_error <- msg
    rducks_arrow_error(msg)
  })
}

rducks_rc_prepare_inputs <- rducks_scalar_prepare_inputs

rducks_make_rc_scalar_bundle <- function(fun, spec,
                                         null_handling = "default",
                                         exception_handling = "rethrow",
                                         plan = rducks_scalar_execution_plan()) {
  engine <- rducks_make_scalar_engine(
    fun, spec,
    null_handling = null_handling,
    exception_handling = exception_handling,
    plan = plan
  )
  list(
    fun = fun,
    arg_types = spec$arg_types,
    return_type = spec$return_type,
    prepare_inputs = rducks_scalar_prepare_inputs,
    check_return = rducks_check_scalar_udf_return,
    result_array = rducks_arrow_result_array,
    eval_rows = rducks_scalar_eval_prepared_rows,
    results_to_arrow = rducks_scalar_results_to_arrow,
    engine = engine,
    plan = plan,
    null_handling = null_handling,
    exception_handling = exception_handling
  )
}

rducks_make_arrow_scalar_wrapper <- function(fun, spec, null_handling, exception_handling,
                                             plan = rducks_scalar_execution_plan()) {
  engine <- rducks_make_scalar_engine(fun, spec, null_handling, exception_handling, plan = plan)
  function(input_array, input_schema, output_schema, n) {
    rducks_scalar_evaluate_arrow_chunk(engine, input_array, input_schema, output_schema, n)
  }
}

rducks_make_arrow_vectorized_wrapper <- function(fun, spec, null_handling, exception_handling,
                                                 plan = rducks_scalar_execution_plan()) {
  engine <- rducks_make_vectorized_engine(fun, spec, null_handling, exception_handling, plan = plan)
  function(input_array, input_schema, output_schema, n) {
    rducks_scalar_evaluate_arrow_chunk(engine, input_array, input_schema, output_schema, n)
  }
}
