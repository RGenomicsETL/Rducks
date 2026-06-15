# Native Rducks chunk representation.
#
# This is SEXP-materializable storage, deliberately not a clone of R's internal
# SEXP layout: side-thread/worker code may serialize this shape, while all actual
# R API object allocation remains on the owning R main thread.

rducks_native_array <- function(type, length, valid, storage) {
  type <- rducks_as_type(type)
  length <- as.integer(length)
  if (length != as.integer(length) || is.na(length) || length < 0L) {
    stop("native array length must be a non-negative integer", call. = FALSE)
  }
  valid <- as.logical(valid)
  if (length(valid) != length) {
    stop("native array validity length does not match array length", call. = FALSE)
  }
  structure(
    list(
      type = type,
      token = rducks_type_token(type),
      length = length,
      valid = valid,
      storage = storage
    ),
    class = "rducks_native_array"
  )
}

rducks_native_chunk <- function(columns, names = NULL, n = NULL) {
  if (!is.list(columns) || !all(vapply(columns, inherits, logical(1), what = "rducks_native_array"))) {
    stop("native chunk columns must be rducks_native_array objects", call. = FALSE)
  }
  if (is.null(names)) names <- names(columns) %||% paste0("V", seq_along(columns))
  if (!is.character(names) || length(names) != length(columns) || anyNA(names) || any(!nzchar(names))) {
    stop("native chunk names must be non-missing character names", call. = FALSE)
  }
  if (anyDuplicated(names)) stop("native chunk names must be unique", call. = FALSE)
  lengths <- vapply(columns, `[[`, integer(1), "length")
  if (is.null(n)) n <- if (length(lengths)) lengths[[1L]] else 0L
  n <- as.integer(n)
  if (any(lengths != n)) stop("native chunk column lengths differ", call. = FALSE)
  names(columns) <- names
  structure(list(n = n, names = names, columns = columns), class = "rducks_native_chunk")
}


rducks_native_scalar_nulls <- function(type, values) {
  if (rducks_type_inherits(type, c("rducks_blob_type", "rducks_geometry_type", "rducks_variant_type", "rducks_bit_type"))) {
    return(!vapply(values, is.null, logical(1)))
  }
  if (rducks_type_inherits(type, "rducks_interval_type")) {
    return(!(is.na(values$months) & is.na(values$days) & is.na(values$micros)))
  }
  if (rducks_type_inherits(type, "rducks_decimal_type")) {
    return(!is.na(as.character(values)))
  }
  if (rducks_type_inherits(type, "rducks_enum_type")) {
    return(!is.na(as.character(values)))
  }
  if (rducks_type_inherits(type, c("rducks_i64_type", "rducks_u64_type", "rducks_hugeint_type", "rducks_uhugeint_type", "rducks_uuid_type"))) {
    return(!is.na(as.character(values)))
  }
  !is.na(values)
}

rducks_native_scalar_normalize <- function(type, values) {
  n <- length(values)
  if (rducks_type_inherits(type, "rducks_bool_type")) {
    return(as.logical(values))
  }
  if (rducks_type_inherits(type, c("rducks_i8_type", "rducks_u8_type", "rducks_i16_type", "rducks_u16_type", "rducks_i32_type", "rducks_r_integer_scalar_type"))) {
    return(as.integer(values))
  }
  if (rducks_type_inherits(type, "rducks_u32_type")) {
    return(as.numeric(values))
  }
  if (rducks_type_inherits(type, c("rducks_f32_type", "rducks_f64_type"))) {
    return(as.numeric(values))
  }
  if (rducks_type_inherits(type, "rducks_varchar_type")) {
    return(as.character(values))
  }
  if (rducks_type_inherits(type, "rducks_date_type")) {
    return(as.Date(values, origin = "1970-01-01"))
  }
  if (rducks_type_inherits(type, "rducks_time_type")) {
    # wire/C storage is microseconds-of-day; canonical TIME is seconds-of-day.
    return(as.numeric(values) / 1e6)
  }
  if (rducks_type_inherits(type, "rducks_timestamp_type")) {
    # wire/C storage is microseconds since epoch; canonical is POSIXct seconds.
    return(as.POSIXct(as.numeric(values) / 1e6, origin = "1970-01-01", tz = "UTC"))
  }
  if (rducks_type_inherits(type, "rducks_i64_type")) return(rducks_bigint(values))
  if (rducks_type_inherits(type, "rducks_u64_type")) return(rducks_ubigint(values))
  if (rducks_type_inherits(type, "rducks_hugeint_type")) return(rducks_hugeint(values))
  if (rducks_type_inherits(type, "rducks_uhugeint_type")) return(rducks_uhugeint(values))
  if (rducks_type_inherits(type, "rducks_uuid_type")) return(rducks_uuid(values))
  if (rducks_type_inherits(type, "rducks_interval_type")) {
    if (inherits(values, "rducks_interval")) return(values)
    if (is.data.frame(values) || is.list(values)) {
      return(rducks_interval(values$months, values$days, values$micros))
    }
    stop("INTERVAL native values must be rducks_interval or months/days/micros storage", call. = FALSE)
  }
  if (rducks_type_inherits(type, "rducks_bit_type")) {
    if (inherits(values, "rducks_bits")) return(list(values))
    if (is.list(values)) return(lapply(values, function(x) if (is.null(x)) NULL else rducks_bits(x)))
    return(list(rducks_bits(values)))
  }
  if (rducks_type_inherits(type, c("rducks_blob_type", "rducks_geometry_type"))) {
    if (is.raw(values)) return(list(values))
    if (!is.list(values) || !all(vapply(values, function(x) is.null(x) || is.raw(x), logical(1)))) {
      stop("BLOB/GEOMETRY native values must be raw or list-of-raw", call. = FALSE)
    }
    return(values)
  }
  if (rducks_type_inherits(type, "rducks_variant_type")) {
    if (inherits(values, "rducks_variant")) return(list(values))
    if (is.list(values) && !is.null(values$keys) && !is.null(values$children) && !is.null(values$values) && !is.null(values$data)) {
      return(list(rducks_variant(values)))
    }
    if (is.list(values)) return(lapply(values, function(x) if (is.null(x)) NULL else rducks_variant(x)))
    stop("VARIANT native values must use rducks_variant storage", call. = FALSE)
  }
  values
}

# Inverse of rducks_native_scalar_normalize: canonical R values -> the C/wire
# storage form the Quack codec (src/quack_codec.c) reads (integer days for DATE,
# double microseconds for TIME/TIMESTAMP, character for 64-bit/128-bit ints/UUID,
# months/days/micros list for INTERVAL, list-of-raw for BLOB/GEOMETRY/BIT).
rducks_native_scalar_to_storage <- function(type, values) {
  if (rducks_type_inherits(type, "rducks_bool_type")) return(as.logical(values))
  if (rducks_type_inherits(type, c("rducks_i8_type", "rducks_u8_type", "rducks_i16_type", "rducks_u16_type", "rducks_i32_type", "rducks_r_integer_scalar_type"))) {
    return(as.integer(values))
  }
  if (rducks_type_inherits(type, "rducks_u32_type")) return(as.numeric(values))
  if (rducks_type_inherits(type, c("rducks_f32_type", "rducks_f64_type"))) return(as.numeric(values))
  if (rducks_type_inherits(type, "rducks_varchar_type")) return(as.character(values))
  if (rducks_type_inherits(type, "rducks_date_type")) return(as.integer(as.numeric(values)))
  if (rducks_type_inherits(type, "rducks_time_type")) return(as.numeric(values) * 1e6)
  if (rducks_type_inherits(type, "rducks_timestamp_type")) return(as.numeric(values) * 1e6)
  if (rducks_type_inherits(type, c("rducks_i64_type", "rducks_u64_type", "rducks_hugeint_type", "rducks_uhugeint_type", "rducks_uuid_type"))) {
    return(as.character(values))
  }
  if (rducks_type_inherits(type, "rducks_interval_type")) {
    if (!inherits(values, "rducks_interval")) values <- rducks_native_scalar_normalize(type, values)
    return(list(months = as.integer(values$months), days = as.integer(values$days), micros = as.numeric(values$micros)))
  }
  if (rducks_type_inherits(type, "rducks_bit_type")) {
    if (inherits(values, "rducks_bits")) return(list(values))
    if (is.list(values)) return(values)
    return(list(values))
  }
  if (rducks_type_inherits(type, c("rducks_blob_type", "rducks_geometry_type"))) {
    if (is.raw(values)) return(list(values))
    return(values)
  }
  if (rducks_type_inherits(type, "rducks_variant_type")) {
    if (is.list(values) && !inherits(values, "rducks_variant")) return(values)
    return(list(values))
  }
  values
}

rducks_native_array_from_scalar <- function(type, values) {
  if (rducks_type_inherits(type, "rducks_interval_type") && is.list(values) && !inherits(values, "rducks_interval")) {
    # Row-wise scalar evaluation yields a list of per-row rducks_interval objects;
    # combine into a single rducks_interval vector (NULL -> NA).
    months <- vapply(values, function(x) if (is.null(x)) NA_integer_ else as.integer(x$months), integer(1))
    days <- vapply(values, function(x) if (is.null(x)) NA_integer_ else as.integer(x$days), integer(1))
    micros <- vapply(values, function(x) if (is.null(x)) NA_real_ else as.numeric(x$micros), numeric(1))
    values <- rducks_interval(months, days, micros)
  } else if (is.list(values) &&
             !rducks_type_inherits(type, c("rducks_blob_type", "rducks_geometry_type",
                                           "rducks_bit_type", "rducks_variant_type"))) {
    # Row-wise scalar evaluation of an atomic scalar type yields a list of per-row
    # length-1 results, with NULL where a row was skipped (default NULL handling).
    # Flatten to an atomic vector (NULL/empty -> NA) so the downstream as.*
    # coercions do not choke on an embedded NULL. BLOB/GEOMETRY/BIT/VARIANT keep
    # their list-of-payloads shape and are excluded above.
    values <- unlist(
      lapply(values, function(x) if (is.null(x) || length(x) == 0L) NA else x),
      use.names = FALSE
    )
  }
  n <- length(values)
  valid <- rducks_native_scalar_nulls(type, values)
  storage_vals <- rducks_native_scalar_to_storage(type, values)
  storage <- if (rducks_type_inherits(type, "rducks_interval_type")) {
    list(kind = "interval", months = storage_vals$months, days = storage_vals$days, micros = storage_vals$micros)
  } else if (rducks_type_inherits(type, c("rducks_blob_type", "rducks_geometry_type", "rducks_bit_type"))) {
    list(kind = "blob", payloads = storage_vals)
  } else {
    list(kind = "scalar", values = storage_vals)
  }
  rducks_native_array(type, n, valid, storage)
}

rducks_native_array_from_decimal <- function(type, values) {
  params <- rducks_type_parameters(type)
  if (is.list(values) && !inherits(values, "rducks_decimal")) {
    # Row-wise scalar evaluation yields a list of per-row (1-element) values;
    # flatten to a character vector (NULL -> NA) before constructing the column.
    values <- vapply(values, function(x) if (is.null(x)) NA_character_ else as.character(x), character(1))
  }
  if (!inherits(values, "rducks_decimal")) values <- rducks_decimal(values, params$width, params$scale)
  if (!identical(as.integer(values$width), as.integer(params$width)) || !identical(as.integer(values$scale), as.integer(params$scale))) {
    values <- rducks_decimal(as.character(values), params$width, params$scale)
  }
  storage <- rducks_decimal_scaled_integer(values)
  rducks_native_array(type, length(values), !is.na(storage), list(kind = "decimal", values = storage))
}

rducks_native_array_from_enum <- function(type, values) {
  levels <- rducks_type_parameters(type)$levels
  if (is.list(values) && !inherits(values, "rducks_enum")) {
    # Row-wise scalar evaluation yields a list of per-row enum scalars, with NULL
    # for skipped rows; flatten to a character label vector (NULL -> NA) before
    # constructing the enum column.
    values <- vapply(values, function(x) if (is.null(x)) NA_character_ else as.character(x), character(1))
  }
  values <- if (inherits(values, "rducks_enum")) rducks_enum(as.character(values), levels = levels) else rducks_enum(values, levels = levels)
  codes <- match(as.character(values), levels)
  rducks_native_array(type, length(values), !is.na(codes), list(kind = "enum", values = codes, levels = levels))
}

rducks_native_sequence_value_at <- function(type, value, i) {
  if (rducks_type_inherits(type, "rducks_scalar_type")) {
    if (rducks_type_inherits(type, c("rducks_blob_type", "rducks_geometry_type", "rducks_variant_type", "rducks_bit_type"))) return(value[[i]])
    return(value[i])
  }
  if (rducks_type_inherits(type, c("rducks_decimal_type", "rducks_enum_type", "rducks_interval_type"))) {
    if (is.list(value) && !inherits(value, c("rducks_decimal", "rducks_enum", "rducks_interval"))) return(value[[i]])
    return(value[i])
  }
  value[[i]]
}

rducks_native_array_from_list <- function(type, values) {
  if (!is.list(values)) stop("LIST values must be a list", call. = FALSE)
  child_type <- rducks_type_children(type)[[1L]]
  n <- length(values)
  valid <- !vapply(values, is.null, logical(1))
  lengths <- vapply(values, function(x) if (is.null(x)) 0L else length(x), integer(1))
  # Per-row start offsets into the flattened child (the wire LIST model is
  # per-row offset + length, matching DuckDB; not a cumulative n+1 offset array).
  offsets <- c(0L, cumsum(lengths))[seq_len(n)]
  flat <- vector("list", sum(lengths))
  pos <- 1L
  for (value in values) {
    if (is.null(value)) next
    for (j in seq_len(length(value))) {
      flat[pos] <- list(rducks_native_sequence_value_at(child_type, value, j))
      pos <- pos + 1L
    }
  }
  child <- rducks_native_array_from_values(child_type, flat)
  rducks_native_array(type, n, valid, list(kind = "list", offsets = offsets, lengths = lengths, child = child))
}

rducks_native_array_from_array <- function(type, values) {
  child_type <- rducks_type_children(type)[[1L]]
  size <- as.integer(rducks_type_size(type))
  if (is.matrix(values)) {
    n <- nrow(values)
    values <- lapply(seq_len(n), function(i) values[i, ])
  } else if (!is.list(values)) {
    stop("ARRAY values must be a list or matrix", call. = FALSE)
  }
  n <- length(values)
  valid <- !vapply(values, is.null, logical(1))
  flat <- vector("list", n * size)
  pos <- 1L
  for (value in values) {
    if (is.null(value)) {
      pos <- pos + size
      next
    }
    if (length(value) != size) stop("ARRAY row has wrong fixed size", call. = FALSE)
    for (j in seq_len(size)) {
      flat[pos] <- list(rducks_native_sequence_value_at(child_type, value, j))
      pos <- pos + 1L
    }
  }
  child <- rducks_native_array_from_values(child_type, flat)
  rducks_native_array(type, n, valid, list(kind = "array", size = size, child = child))
}

rducks_native_array_from_struct <- function(type, values) {
  children <- rducks_type_children(type)
  child_names <- rducks_type_child_names(type)
  if (is.data.frame(values)) {
    n <- nrow(values)
    valid <- rep(TRUE, n)
    fields <- stats::setNames(vector("list", length(children)), child_names)
    for (i in seq_along(children)) {
      field <- child_names[[i]]
      if (!field %in% names(values)) stop("STRUCT field missing from data frame: ", field, call. = FALSE)
      fields[[i]] <- rducks_native_array_from_values(children[[i]], values[[field]])
    }
    return(rducks_native_array(type, n, valid, list(kind = "struct", fields = fields)))
  }
  if (!is.list(values)) stop("STRUCT values must be a data frame or list of rows", call. = FALSE)
  n <- length(values)
  valid <- !vapply(values, is.null, logical(1))
  fields <- stats::setNames(vector("list", length(children)), child_names)
  for (i in seq_along(children)) {
    field <- child_names[[i]]
    vals <- lapply(values, function(x) if (is.null(x)) NULL else x[[field]])
    fields[[i]] <- rducks_native_array_from_values(children[[i]], vals)
  }
  rducks_native_array(type, n, valid, list(kind = "struct", fields = fields))
}

rducks_native_array_from_map <- function(type, values) {
  if (!is.list(values)) stop("MAP values must be a list", call. = FALSE)
  children <- rducks_type_children(type)
  key_type <- children[[1L]]
  value_type <- children[[2L]]
  n <- length(values)
  valid <- !vapply(values, is.null, logical(1))
  lengths <- vapply(values, function(x) {
    if (is.null(x)) return(0L)
    if (!is.list(x) || is.null(x$keys) || is.null(x$values)) stop("MAP values must be list(keys = ..., values = ...)", call. = FALSE)
    if (length(x$keys) != length(x$values)) stop("MAP keys and values must have equal length", call. = FALSE)
    length(x$keys)
  }, integer(1))
  # Per-row start offsets into the flattened entries (wire MAP is per-row
  # offset + length, like LIST; not a cumulative n+1 array).
  offsets <- c(0L, cumsum(lengths))[seq_len(n)]
  flat_keys <- vector("list", sum(lengths))
  flat_values <- vector("list", sum(lengths))
  pos <- 1L
  for (value in values) {
    if (is.null(value)) next
    for (j in seq_len(length(value$keys))) {
      flat_keys[pos] <- list(rducks_native_sequence_value_at(key_type, value$keys, j))
      flat_values[pos] <- list(rducks_native_sequence_value_at(value_type, value$values, j))
      pos <- pos + 1L
    }
  }
  keys <- rducks_native_array_from_values(key_type, flat_keys)
  vals <- rducks_native_array_from_values(value_type, flat_values)
  rducks_native_array(type, n, valid, list(kind = "map", offsets = offsets, lengths = lengths, keys = keys, values = vals))
}

rducks_native_array_from_union <- function(type, values) {
  if (inherits(values, "rducks_union")) values <- list(values)
  if (!is.list(values)) stop("UNION values must be a list of rducks_union values", call. = FALSE)
  children <- rducks_type_children(type)
  child_names <- rducks_type_child_names(type)
  n <- length(values)
  valid <- !vapply(values, is.null, logical(1))
  tags <- rep.int(NA_integer_, n)
  child_values <- replicate(length(children), vector("list", n), simplify = FALSE)
  for (i in seq_along(values)) {
    value <- values[[i]]
    if (is.null(value)) next
    if (!inherits(value, "rducks_union")) value <- rducks_union(value$tag, value$value)
    tag_index <- match(value$tag, child_names)
    if (is.na(tag_index)) stop("union tag must be one of: ", paste(child_names, collapse = ", "), call. = FALSE)
    tags[[i]] <- tag_index
    child_values[[tag_index]][i] <- list(value$value)
  }
  members <- stats::setNames(vector("list", length(children)), child_names)
  for (j in seq_along(children)) {
    members[[j]] <- rducks_native_array_from_values(children[[j]], child_values[[j]])
  }
  rducks_native_array(type, n, valid, list(kind = "union", tags = tags, members = members))
}

rducks_native_array_from_values <- function(type, values) {
  type <- rducks_as_type(type)
  if (rducks_type_inherits(type, "rducks_scalar_type")) return(rducks_native_array_from_scalar(type, values))
  if (rducks_type_inherits(type, "rducks_decimal_type")) return(rducks_native_array_from_decimal(type, values))
  if (rducks_type_inherits(type, "rducks_enum_type")) return(rducks_native_array_from_enum(type, values))
  if (rducks_type_inherits(type, "rducks_list_type")) return(rducks_native_array_from_list(type, values))
  if (rducks_type_inherits(type, "rducks_array_type")) return(rducks_native_array_from_array(type, values))
  if (rducks_type_inherits(type, "rducks_struct_type")) return(rducks_native_array_from_struct(type, values))
  if (rducks_type_inherits(type, "rducks_map_type")) return(rducks_native_array_from_map(type, values))
  if (rducks_type_inherits(type, "rducks_union_type")) return(rducks_native_array_from_union(type, values))
  stop("unsupported Rducks type for native array: ", rducks_type_duckdb_sql(type), call. = FALSE)
}


rducks_native_array_to_values <- function(array) {
  if (!inherits(array, "rducks_native_array")) stop("expected rducks_native_array", call. = FALSE)
  type <- array$type
  n <- array$length
  storage <- array$storage
  if (rducks_type_inherits(type, "rducks_interval_type")) {
    return(rducks_native_scalar_normalize(type, list(months = storage$months, days = storage$days, micros = storage$micros)))
  }
  if (rducks_type_inherits(type, c("rducks_blob_type", "rducks_geometry_type", "rducks_bit_type"))) {
    return(rducks_native_scalar_normalize(type, storage$payloads))
  }
  if (rducks_type_inherits(type, "rducks_scalar_type")) {
    return(rducks_native_scalar_normalize(type, storage$values))
  }
  if (rducks_type_inherits(type, "rducks_decimal_type")) {
    params <- rducks_type_parameters(type)
    return(rducks_decimal_from_scaled_integer(storage$values, params$width, params$scale))
  }
  if (rducks_type_inherits(type, "rducks_enum_type")) {
    levels <- rducks_type_parameters(type)$levels
    codes <- storage$values
    labels <- ifelse(is.na(codes), NA_character_, levels[codes])
    return(rducks_enum(labels, levels = levels))
  }
  if (rducks_type_inherits(type, "rducks_list_type")) {
    child_values <- rducks_native_array_to_values(storage$child)
    out <- vector("list", n)
    for (i in seq_len(n)) {
      if (!isTRUE(array$valid[[i]])) next
      len <- storage$lengths[[i]]
      start <- storage$offsets[[i]] + 1L
      rows <- if (len > 0) start:(storage$offsets[[i]] + len) else integer()
      out[[i]] <- child_values[rows]
    }
    return(out)
  }
  if (rducks_type_inherits(type, "rducks_array_type")) {
    child_values <- rducks_native_array_to_values(storage$child)
    size <- storage$size
    out <- vector("list", n)
    for (i in seq_len(n)) {
      if (!isTRUE(array$valid[[i]])) next
      rows <- ((i - 1L) * size + 1L):(i * size)
      out[[i]] <- child_values[rows]
    }
    return(out)
  }
  if (rducks_type_inherits(type, "rducks_struct_type")) {
    child_names <- rducks_type_child_names(type)
    field_values <- lapply(storage$fields, rducks_native_array_to_values)
    out <- vector("list", n)
    for (i in seq_len(n)) {
      if (!isTRUE(array$valid[[i]])) next
      row <- stats::setNames(vector("list", length(child_names)), child_names)
      # Single-bracket list assignment so a NULL field value (e.g. a NULL nested
      # column entry) keeps the field instead of deleting it from the row.
      for (j in seq_along(child_names)) {
        row[j] <- list(rducks_native_sequence_value_at(rducks_type_children(type)[[j]], field_values[[j]], i))
      }
      out[[i]] <- row
    }
    return(out)
  }
  if (rducks_type_inherits(type, "rducks_map_type")) {
    keys <- rducks_native_array_to_values(storage$keys)
    values <- rducks_native_array_to_values(storage$values)
    out <- vector("list", n)
    for (i in seq_len(n)) {
      if (!isTRUE(array$valid[[i]])) next
      len <- storage$lengths[[i]]
      start <- storage$offsets[[i]] + 1L
      rows <- if (len > 0) start:(storage$offsets[[i]] + len) else integer()
      out[[i]] <- list(keys = keys[rows], values = values[rows])
    }
    return(out)
  }
  if (rducks_type_inherits(type, "rducks_union_type")) {
    child_names <- rducks_type_child_names(type)
    child_types <- rducks_type_children(type)
    member_values <- lapply(storage$members, rducks_native_array_to_values)
    out <- vector("list", n)
    for (i in seq_len(n)) {
      if (!isTRUE(array$valid[[i]])) next
      tag_index <- storage$tags[[i]]
      out[[i]] <- rducks_union(child_names[[tag_index]], rducks_native_sequence_value_at(child_types[[tag_index]], member_values[[tag_index]], i))
    }
    class(out) <- c("rducks_union_list", "list")
    return(out)
  }
  stop("unsupported native array storage kind: ", storage$kind %||% "<unknown>", call. = FALSE)
}

rducks_native_chunk_from_data_frame <- function(result, types = NULL) {
  result <- rducks_table_result_as_data_frame(result)
  names <- names(result)
  if (is.null(types)) {
    types <- lapply(result, rducks_native_infer_type)
  } else {
    types <- rducks_as_type_list(types)
  }
  if (length(types) != length(result)) stop("types length does not match data-frame columns", call. = FALSE)
  columns <- vector("list", length(result))
  for (i in seq_along(result)) columns[[i]] <- rducks_native_array_from_values(types[[i]], result[[i]])
  rducks_native_chunk(columns, names = names, n = nrow(result))
}

rducks_native_chunk_to_data_frame <- function(chunk) {
  if (!inherits(chunk, "rducks_native_chunk")) stop("expected rducks_native_chunk", call. = FALSE)
  out <- lapply(chunk$columns, rducks_native_array_to_values)
  names(out) <- chunk$names
  structure(out, names = chunk$names, class = "data.frame", row.names = .set_row_names(chunk$n))
}

rducks_native_infer_type <- function(x) {
  if (inherits(x, "rducks_bigint")) return(BIGINT)
  if (inherits(x, "rducks_ubigint")) return(UBIGINT)
  if (inherits(x, "rducks_hugeint")) return(HUGEINT)
  if (inherits(x, "rducks_uhugeint")) return(UHUGEINT)
  if (inherits(x, "rducks_uuid")) return(UUID)
  if (inherits(x, "rducks_decimal")) return(DECIMAL(x$width, x$scale))
  if (inherits(x, "rducks_interval")) return(INTERVAL)
  if (inherits(x, "rducks_enum")) return(ENUM(levels(x)))
  if (inherits(x, "Date")) return(DATE)
  if (inherits(x, "POSIXct")) return(TIMESTAMP)
  if (inherits(x, "factor")) return(ENUM(levels(x)))
  if (is.logical(x)) return(BOOLEAN)
  if (is.integer(x)) return(INTEGER)
  if (is.double(x)) return(DOUBLE)
  if (is.character(x)) return(VARCHAR)
  if (is.raw(x)) return(BLOB)
  if (is.list(x) && all(vapply(x, function(value) is.null(value) || is.raw(value), logical(1)))) return(BLOB)
  stop("cannot infer Rducks native type for column; supply explicit types", call. = FALSE)
}
