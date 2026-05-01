rducks_arrow_top_level_null_is_r_null <- function(type) {
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
  if (!length(validity)) {
    rep(TRUE, n)
  } else {
    validity[seq_len(n)]
  }
}

rducks_arrow_validity_buffer <- function(valid) {
  valid <- as.logical(valid)
  if (all(valid)) {
    return(NULL)
  }
  nanoarrow::as_nanoarrow_array(valid, schema = nanoarrow::na_bool())$buffers[[2L]]
}

rducks_arrow_divmod_decimal_string <- function(digits, divisor = 256L) {
  carry <- 0L
  out <- integer()
  started <- FALSE
  for (digit in digits) {
    value <- carry * 10L + digit
    q <- value %/% divisor
    carry <- value %% divisor
    if (q != 0L || started) {
      out <- c(out, q)
      started <- TRUE
    }
  }
  list(q = out, r = carry)
}

rducks_arrow_unsigned_bytes_from_decimal <- function(x, width) {
  x <- sub("^\\+", "", x)
  x <- sub("^0+", "", x)
  if (!nzchar(x)) x <- "0"
  if (!grepl("^[0-9]+$", x)) {
    stop("expected an unsigned decimal integer string", call. = FALSE)
  }
  digits <- as.integer(strsplit(x, "", fixed = TRUE)[[1L]])
  out <- integer(width)
  for (i in seq_len(width)) {
    if (!length(digits)) break
    qr <- rducks_arrow_divmod_decimal_string(digits)
    out[[i]] <- qr$r
    digits <- qr$q
  }
  if (length(digits)) {
    stop("integer value does not fit in Arrow storage", call. = FALSE)
  }
  as.raw(out)
}

rducks_arrow_twos_complement_bytes <- function(x, width) {
  if (is.na(x)) {
    return(raw(width))
  }
  x <- trimws(as.character(x))
  neg <- startsWith(x, "-")
  if (neg) x <- substring(x, 2L)
  bytes <- as.integer(rducks_arrow_unsigned_bytes_from_decimal(x, width))
  if (neg) {
    bytes <- 255L - bytes
    carry <- 1L
    for (i in seq_len(width)) {
      value <- bytes[[i]] + carry
      bytes[[i]] <- value %% 256L
      carry <- value %/% 256L
      if (!carry) break
    }
  }
  as.raw(bytes)
}

rducks_arrow_decimal_unscale_string <- function(x, scale) {
  if (is.na(x)) return(NA_character_)
  x <- trimws(as.character(x))
  sign <- ""
  if (startsWith(x, "-")) {
    sign <- "-"
    x <- substring(x, 2L)
  }
  x <- sub("^0+", "", x)
  if (!nzchar(x)) x <- "0"
  if (scale > 0L) {
    x <- paste0(strrep("0", max(0L, scale + 1L - nchar(x))), x)
    whole <- substr(x, 1L, nchar(x) - scale)
    frac <- substr(x, nchar(x) - scale + 1L, nchar(x))
    whole <- sub("^0+", "", whole)
    if (!nzchar(whole)) whole <- "0"
    paste0(sign, whole, ".", frac)
  } else {
    paste0(sign, x)
  }
}

rducks_arrow_decimal_array_to_values <- function(array, width, scale) {
  n <- as.integer(array$length)
  data <- as.raw(array$buffers[[2L]])
  storage_width <- as.integer(length(data) / max(1L, n))
  storage_width <- if (storage_width %in% c(4L, 8L, 16L, 32L)) storage_width else 16L
  storage <- rducks_arrow_fixed_width_array_to_decimal(array, storage_width, signed = TRUE)
  rducks_decimal(vapply(storage, rducks_arrow_decimal_unscale_string, character(1), scale = scale), width, scale)
}

rducks_arrow_decimal_storage_string <- function(x, scale) {
  if (is.na(x)) return(NA_character_)
  x <- trimws(as.character(x))
  sign <- ""
  if (startsWith(x, "+")) x <- substring(x, 2L)
  if (startsWith(x, "-")) {
    sign <- "-"
    x <- substring(x, 2L)
  }
  parts <- strsplit(x, ".", fixed = TRUE)[[1L]]
  whole <- parts[[1L]]
  frac <- if (length(parts) > 1L) parts[[2L]] else ""
  frac <- paste0(frac, strrep("0", max(0L, scale - nchar(frac))))
  frac <- substr(frac, 1L, scale)
  digits <- paste0(whole, frac)
  digits <- sub("^0+", "", digits)
  if (!nzchar(digits)) digits <- "0"
  paste0(sign, digits)
}

rducks_arrow_add_decimal_string_small <- function(x, addend) {
  x <- trimws(as.character(x))
  x <- sub("^0+", "", x)
  if (!nzchar(x)) x <- "0"
  digits <- rev(as.integer(strsplit(x, "", fixed = TRUE)[[1L]]))
  carry <- as.integer(addend)
  out <- integer(max(length(digits), 1L) + 8L)
  pos <- 1L
  while (pos <= length(digits) || carry > 0L) {
    digit <- if (pos <= length(digits)) digits[[pos]] else 0L
    value <- digit + carry
    out[[pos]] <- value %% 10L
    carry <- value %/% 10L
    pos <- pos + 1L
  }
  ans <- paste0(rev(out[seq_len(pos - 1L)]), collapse = "")
  ans <- sub("^0+", "", ans)
  if (!nzchar(ans)) "0" else ans
}

rducks_arrow_multiply_decimal_string_small <- function(x, multiplier) {
  if (is.na(x)) return(NA_character_)
  x <- trimws(as.character(x))
  sign <- ""
  if (startsWith(x, "+")) x <- substring(x, 2L)
  if (startsWith(x, "-")) {
    sign <- "-"
    x <- substring(x, 2L)
  }
  digits <- rev(as.integer(strsplit(sub("^0+", "", x), "", fixed = TRUE)[[1L]]))
  if (!length(digits) || anyNA(digits)) return("0")
  carry <- 0L
  out <- integer(length(digits) + 8L)
  pos <- 1L
  for (digit in digits) {
    value <- digit * multiplier + carry
    out[[pos]] <- value %% 10L
    carry <- value %/% 10L
    pos <- pos + 1L
  }
  while (carry > 0L) {
    out[[pos]] <- carry %% 10L
    carry <- carry %/% 10L
    pos <- pos + 1L
  }
  chars <- rev(out[seq_len(pos - 1L)])
  chars <- chars[!(seq_along(chars) == 1L & chars == 0L)]
  ans <- paste0(chars, collapse = "")
  ans <- sub("^0+", "", ans)
  if (!nzchar(ans)) ans <- "0"
  paste0(sign, ans)
}

rducks_arrow_decimal_string_from_unsigned_bytes <- function(bytes) {
  out <- "0"
  for (byte in rev(as.integer(bytes))) {
    out <- rducks_arrow_multiply_decimal_string_small(out, 256L)
    out <- rducks_arrow_add_decimal_string_small(out, byte)
  }
  out
}

rducks_arrow_decimal_string_from_twos_complement <- function(bytes, signed = TRUE) {
  ints <- as.integer(bytes)
  if (!signed || !length(ints) || ints[[length(ints)]] < 128L) {
    return(rducks_arrow_decimal_string_from_unsigned_bytes(as.raw(ints)))
  }
  ints <- 255L - ints
  carry <- 1L
  for (i in seq_along(ints)) {
    value <- ints[[i]] + carry
    ints[[i]] <- value %% 256L
    carry <- value %/% 256L
    if (!carry) break
  }
  paste0("-", rducks_arrow_decimal_string_from_unsigned_bytes(as.raw(ints)))
}

rducks_arrow_fixed_width_array_to_decimal <- function(array, width, signed = TRUE) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  bytes <- as.raw(array$buffers[[2L]])
  out <- rep(NA_character_, n)
  for (i in seq_len(n)) {
    if (!isTRUE(valid[[i]])) next
    start <- (offset + i - 1L) * width + 1L
    out[[i]] <- rducks_arrow_decimal_string_from_twos_complement(bytes[start + seq_len(width) - 1L], signed = signed)
  }
  out
}

rducks_arrow_fixed_width_array <- function(values, schema, width, signed = TRUE) {
  values <- as.character(values)
  valid <- !is.na(values)
  data <- do.call(c, lapply(values, rducks_arrow_twos_complement_bytes, width = width))
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

rducks_arrow_divide_decimal_string_small <- function(x, divisor) {
  if (is.na(x)) return(NA_character_)
  x <- trimws(as.character(x))
  sign <- ""
  if (startsWith(x, "-")) {
    sign <- "-"
    x <- substring(x, 2L)
  }
  digits <- as.integer(strsplit(sub("^0+", "", x), "", fixed = TRUE)[[1L]])
  if (!length(digits) || anyNA(digits)) return("0")
  qr <- rducks_arrow_divmod_decimal_string(digits, as.integer(divisor))
  out <- paste0(qr$q, collapse = "")
  out <- sub("^0+", "", out)
  if (!nzchar(out)) out <- "0"
  paste0(if (identical(out, "0")) "" else sign, out)
}

rducks_arrow_interval_array_to_values <- function(array) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  bytes <- as.raw(array$buffers[[2L]])
  months <- rep(NA_integer_, n)
  days <- rep(NA_integer_, n)
  micros <- rep(NA_character_, n)
  for (i in seq_len(n)) {
    if (!isTRUE(valid[[i]])) next
    start <- (offset + i - 1L) * 16L + 1L
    months[[i]] <- readBin(bytes[start + 0:3], integer(), size = 4L, endian = "little", signed = TRUE)
    days[[i]] <- readBin(bytes[start + 4:7], integer(), size = 4L, endian = "little", signed = TRUE)
    nanos <- rducks_arrow_decimal_string_from_twos_complement(bytes[start + 8:15], signed = TRUE)
    micros[[i]] <- rducks_arrow_divide_decimal_string_small(nanos, 1000L)
  }
  rducks_interval(months, days, micros)
}

rducks_arrow_uuid_array_to_character <- function(array) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  bytes <- as.raw(array$buffers[[1L]])
  # Fixed-size binary arrays do not have a validity-only first buffer when
  # accessed through nanoarrow; account for both fixed-size-binary and binary
  # proxy shapes.
  data_buffer_index <- if (length(array$buffers) >= 2L) 2L else 1L
  bytes <- as.raw(array$buffers[[data_buffer_index]])
  out <- rep(NA_character_, n)
  for (i in seq_len(n)) {
    if (!isTRUE(valid[[i]])) next
    start <- (offset + i - 1L) * 16L + 1L
    hex <- paste0(sprintf("%02x", as.integer(bytes[start + 0:15])), collapse = "")
    out[[i]] <- paste(
      substr(hex, 1L, 8L), substr(hex, 9L, 12L), substr(hex, 13L, 16L),
      substr(hex, 17L, 20L), substr(hex, 21L, 32L),
      sep = "-"
    )
  }
  out
}

rducks_arrow_uuid_array <- function(values, schema) {
  values <- as.character(values)
  valid <- !is.na(values)
  one <- function(x) {
    if (is.na(x)) return(raw(16L))
    hex <- gsub("-", "", tolower(x), fixed = TRUE)
    if (!grepl("^[0-9a-f]{32}$", hex)) stop("invalid UUID value", call. = FALSE)
    as.raw(strtoi(substring(hex, seq(1L, 31L, 2L), seq(2L, 32L, 2L)), 16L))
  }
  data <- do.call(c, lapply(values, one))
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
  valid <- !vapply(values, is.null, logical(1))
  months <- integer(length(values))
  days <- integer(length(values))
  nanos <- character(length(values))
  nanos[] <- "0"
  for (i in seq_along(values)) {
    if (!valid[[i]]) next
    value <- values[[i]]
    if (!inherits(value, "rducks_interval")) value <- rducks_interval(value$months, value$days, value$micros)
    months[[i]] <- value$months[[1L]]
    days[[i]] <- value$days[[1L]]
    nanos[[i]] <- rducks_arrow_multiply_decimal_string_small(value$micros[[1L]], 1000L)
    if (is.na(value$months[[1L]]) || is.na(value$days[[1L]]) || is.na(value$micros[[1L]])) valid[[i]] <- FALSE
  }
  data <- raw(16L * length(values))
  for (i in seq_along(values)) {
    off <- (i - 1L) * 16L
    data[off + seq_len(4L)] <- writeBin(as.integer(months[[i]]), raw(), size = 4L, endian = "little")
    data[off + 4L + seq_len(4L)] <- writeBin(as.integer(days[[i]]), raw(), size = 4L, endian = "little")
    data[off + 8L + seq_len(8L)] <- rducks_arrow_twos_complement_bytes(nanos[[i]], 8L)
  }
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
  out <- bytes[offset + seq_len(n)] != as.raw(0)
  out[!valid] <- NA
  out
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

rducks_arrow_microsecond_strings <- function(values) {
  vapply(values, function(x) {
    if (is.null(x) || is.na(x)) return(NA_character_)
    format(round(as.numeric(x) * 1000000), scientific = FALSE, trim = TRUE)
  }, character(1))
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
  rducks_arrow_fixed_width_array(rducks_arrow_microsecond_strings(values), schema, 8L, signed = TRUE)
}

rducks_arrow_timestamp_array <- function(values, schema) {
  rducks_arrow_fixed_width_array(rducks_arrow_microsecond_strings(values), schema, 8L, signed = TRUE)
}

rducks_arrow_binary_payload_array <- function(payloads, schema) {
  valid <- !vapply(payloads, is.null, logical(1))
  lengths <- vapply(payloads, function(x) if (is.null(x)) 0L else length(x), integer(1))
  offsets <- c(0L, cumsum(lengths))
  data <- if (sum(lengths)) do.call(c, payloads[valid]) else raw()
  array <- nanoarrow::nanoarrow_array_init(schema)
  nanoarrow::nanoarrow_array_modify(
    array,
    list(
      length = length(payloads),
      null_count = sum(!valid),
      buffers = list(rducks_arrow_validity_buffer(valid), as.integer(offsets), data)
    )
  )
}

rducks_arrow_bit_payload_to_value <- function(payload) {
  if (length(payload) < 2L) stop("invalid Arrow BIT payload", call. = FALSE)
  padding <- as.integer(payload[[1L]])
  if (padding < 0L || padding > 7L) stop("invalid Arrow BIT padding", call. = FALSE)
  data <- as.integer(payload[-1L])
  bits <- integer((length(payload) - 1L) * 8L - padding)
  pos <- 1L
  for (byte_idx in seq_along(data)) {
    start_bit <- if (byte_idx == 1L) padding else 0L
    for (bit_idx in start_bit:7L) {
      if (pos > length(bits)) break
      bits[[pos]] <- bitwAnd(bitwShiftR(data[[byte_idx]], 7L - bit_idx), 1L)
      pos <- pos + 1L
    }
  }
  rducks_bits(bits)
}

rducks_arrow_bit_value_to_payload <- function(value) {
  value <- rducks_bits(value)
  bits <- as.integer(value)
  n <- length(bits)
  padding <- (8L - (n %% 8L)) %% 8L
  payload <- raw(1L + ceiling(n / 8L))
  payload[[1L]] <- as.raw(padding)
  if (padding > 0L) {
    for (bit_idx in seq_len(padding)) {
      payload[[2L]] <- as.raw(bitwOr(as.integer(payload[[2L]]), bitwShiftL(1L, 8L - bit_idx)))
    }
  }
  for (i in seq_len(n)) {
    storage_bit <- padding + i - 1L
    byte <- storage_bit %/% 8L + 2L
    bit_idx <- storage_bit %% 8L
    if (bits[[i]]) {
      payload[[byte]] <- as.raw(bitwOr(as.integer(payload[[byte]]), bitwShiftL(1L, 7L - bit_idx)))
    }
  }
  payload
}

rducks_arrow_bit_array_to_values <- function(array) {
  n <- as.integer(array$length)
  offset <- as.integer(array$offset %||% 0L)
  valid <- rducks_arrow_validity(array, n)
  offsets <- as.integer(as.vector(array$buffers[[2L]]))
  data <- as.raw(array$buffers[[3L]])
  out <- vector("list", n)
  for (i in seq_len(n)) {
    if (!isTRUE(valid[[i]])) next
    start <- offsets[[offset + i]] + 1L
    end <- offsets[[offset + i + 1L]]
    out[[i]] <- rducks_arrow_bit_payload_to_value(data[start:end])
  }
  out
}

rducks_arrow_bit_array <- function(values, schema) {
  payloads <- lapply(values, function(x) if (is.null(x)) NULL else rducks_arrow_bit_value_to_payload(x))
  rducks_arrow_binary_payload_array(payloads, schema)
}

rducks_arrow_enum_storage_schema <- function(schema) {
  out <- nanoarrow::as_nanoarrow_schema(schema)
  out$dictionary <- NULL
  out
}

rducks_arrow_enum_storage_array <- function(chars, levels, schema) {
  storage_schema <- rducks_arrow_enum_storage_schema(schema)
  valid <- !is.na(chars)
  idx <- match(chars, levels) - 1L
  idx[!valid] <- NA_integer_
  if (any(is.na(idx) & valid)) stop("enum values must be present in levels", call. = FALSE)
  array <- nanoarrow::as_nanoarrow_array(idx, schema = storage_schema)
  nanoarrow::nanoarrow_array_set_schema(array, storage_schema)
  array
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
    if (tag_index < 1L || tag_index > length(children)) stop("invalid Arrow UNION tag", call. = FALSE)
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

rducks_arrow_import_schema <- function(type, output_schema) {
  if (!inherits(type, "rducks_enum_type")) return(output_schema)
  schema <- nanoarrow::as_nanoarrow_schema(output_schema)
  schema$children[[1L]] <- rducks_arrow_enum_storage_schema(schema$children[[1L]])
  schema
}

rducks_arrow_scalar_array_to_values <- function(type, array, schema = NULL) {
  UseMethod("rducks_arrow_scalar_array_to_values")
}

rducks_arrow_scalar_array_to_values.rducks_bool_type <- function(type, array, schema = NULL) {
  if (identical(rducks_arrow_schema_extension_name(schema), "arrow.bool8")) {
    rducks_arrow_bool8_array_to_logical(array)
  } else {
    nanoarrow::convert_array(array, to = logical())
  }
}

rducks_arrow_scalar_array_to_values.rducks_r_integer_scalar_type <- function(type, array, schema = NULL) {
  as.integer(nanoarrow::convert_array(array, to = integer()))
}

rducks_arrow_scalar_array_to_values.rducks_u32_type <- function(type, array, schema = NULL) {
  as.numeric(nanoarrow::convert_array(array, to = numeric()))
}

rducks_arrow_scalar_array_to_values.rducks_i64_type <- function(type, array, schema = NULL) {
  rducks_bigint(rducks_arrow_fixed_width_array_to_decimal(array, 8L, signed = TRUE))
}

rducks_arrow_scalar_array_to_values.rducks_u64_type <- function(type, array, schema = NULL) {
  rducks_ubigint(rducks_arrow_fixed_width_array_to_decimal(array, 8L, signed = FALSE))
}

rducks_arrow_scalar_array_to_values.rducks_floating_scalar_type <- function(type, array, schema = NULL) {
  as.numeric(nanoarrow::convert_array(array, to = numeric()))
}

rducks_arrow_scalar_array_to_values.rducks_varchar_type <- function(type, array, schema = NULL) {
  as.character(nanoarrow::convert_array(array, to = character()))
}

rducks_arrow_scalar_array_to_values.rducks_blob_type <- function(type, array, schema = NULL) {
  as.list(nanoarrow::convert_array(array))
}

rducks_arrow_scalar_array_to_values.rducks_date_type <- function(type, array, schema = NULL) {
  nanoarrow::convert_array(array, to = as.Date(character()))
}

rducks_arrow_scalar_array_to_values.rducks_time_type <- function(type, array, schema = NULL) {
  as.numeric(nanoarrow::convert_array(array))
}

rducks_arrow_scalar_array_to_values.rducks_timestamp_type <- function(type, array, schema = NULL) {
  nanoarrow::convert_array(array, to = as.POSIXct(character(), tz = "UTC"))
}

rducks_arrow_scalar_array_to_values.rducks_hugeint_type <- function(type, array, schema = NULL) {
  rducks_hugeint(rducks_arrow_fixed_width_array_to_decimal(array, 16L, signed = TRUE))
}

rducks_arrow_scalar_array_to_values.rducks_uhugeint_type <- function(type, array, schema = NULL) {
  rducks_uhugeint(rducks_arrow_fixed_width_array_to_decimal(array, 16L, signed = FALSE))
}

rducks_arrow_scalar_array_to_values.rducks_uuid_type <- function(type, array, schema = NULL) {
  if (identical(rducks_arrow_schema_extension_name(schema), "arrow.uuid")) {
    rducks_uuid(rducks_arrow_uuid_array_to_character(array))
  } else {
    rducks_uuid(nanoarrow::convert_array(array, to = character()))
  }
}

rducks_arrow_scalar_array_to_values.rducks_interval_type <- function(type, array, schema = NULL) {
  rducks_arrow_interval_array_to_values(array)
}

rducks_arrow_scalar_array_to_values.rducks_bit_type <- function(type, array, schema = NULL) {
  rducks_arrow_bit_array_to_values(array)
}

rducks_arrow_scalar_array_to_values.rducks_scalar_type <- function(type, array, schema = NULL) {
  nanoarrow::convert_array(array)
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
    return(rducks_enum(nanoarrow::convert_array(array, to = character()), levels = rducks_type_parameters(type)$levels))
  }
  if (inherits(type, "rducks_map_type")) {
    return(rducks_arrow_map_array_to_values(type, array, schema))
  }
  if (inherits(type, "rducks_union_type")) {
    return(rducks_arrow_union_array_to_values(type, array, schema))
  }
  nanoarrow::convert_array(array)
}

rducks_arrow_value_at <- function(type, values, nulls, i) {
  if (isTRUE(nulls[[i]])) {
    if (rducks_arrow_top_level_null_is_r_null(type) || !inherits(type, "rducks_scalar_type")) {
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

rducks_arrow_scalar_values_to_array <- function(type, results, schema) {
  UseMethod("rducks_arrow_scalar_values_to_array")
}

rducks_arrow_scalar_values_to_array.rducks_bool_type <- function(type, results, schema) {
  values <- rducks_arrow_results_as_logical(results)
  if (identical(rducks_arrow_schema_extension_name(schema), "arrow.bool8")) {
    rducks_arrow_bool8_array(values, schema)
  } else {
    nanoarrow::as_nanoarrow_array(values, schema = schema)
  }
}

rducks_arrow_scalar_values_to_array.rducks_r_integer_scalar_type <- function(type, results, schema) {
  nanoarrow::as_nanoarrow_array(rducks_arrow_results_as_integer(results), schema = schema)
}

rducks_arrow_scalar_values_to_array.rducks_u32_type <- function(type, results, schema) {
  nanoarrow::as_nanoarrow_array(rducks_arrow_results_as_numeric(results), schema = schema)
}

rducks_arrow_scalar_values_to_array.rducks_f32_type <- function(type, results, schema) {
  rducks_arrow_float_array(rducks_arrow_results_as_numeric(results), schema, 4L)
}

rducks_arrow_scalar_values_to_array.rducks_f64_type <- function(type, results, schema) {
  rducks_arrow_float_array(rducks_arrow_results_as_numeric(results), schema, 8L)
}

rducks_arrow_scalar_values_to_array.rducks_varchar_type <- function(type, results, schema) {
  nanoarrow::as_nanoarrow_array(rducks_arrow_results_as_character(results), schema = schema)
}

rducks_arrow_scalar_values_to_array.rducks_date_type <- function(type, results, schema) {
  values <- as.Date(rducks_arrow_results_as_numeric(results), origin = "1970-01-01")
  nanoarrow::as_nanoarrow_array(values, schema = schema)
}

rducks_arrow_scalar_values_to_array.rducks_time_type <- function(type, results, schema) {
  rducks_arrow_time_array(rducks_arrow_results_as_numeric(results), schema)
}

rducks_arrow_scalar_values_to_array.rducks_timestamp_type <- function(type, results, schema) {
  values <- as.POSIXct(rducks_arrow_results_as_numeric(results), origin = "1970-01-01", tz = "UTC")
  rducks_arrow_timestamp_array(values, schema)
}

rducks_arrow_scalar_values_to_array.rducks_i64_type <- function(type, results, schema) {
  values <- rducks_bigint(rducks_arrow_results_as_character(results))
  rducks_arrow_fixed_width_array(values, schema, 8L, signed = TRUE)
}

rducks_arrow_scalar_values_to_array.rducks_u64_type <- function(type, results, schema) {
  values <- rducks_ubigint(rducks_arrow_results_as_character(results))
  rducks_arrow_fixed_width_array(values, schema, 8L, signed = FALSE)
}

rducks_arrow_scalar_values_to_array.rducks_hugeint_type <- function(type, results, schema) {
  values <- rducks_hugeint(rducks_arrow_results_as_character(results))
  rducks_arrow_fixed_width_array(values, schema, 16L, signed = TRUE)
}

rducks_arrow_scalar_values_to_array.rducks_uhugeint_type <- function(type, results, schema) {
  values <- rducks_uhugeint(rducks_arrow_results_as_character(results))
  rducks_arrow_fixed_width_array(values, schema, 16L, signed = FALSE)
}

rducks_arrow_scalar_values_to_array.rducks_uuid_type <- function(type, results, schema) {
  values <- rducks_uuid(rducks_arrow_results_as_character(results))
  parsed <- try(nanoarrow::nanoarrow_schema_parse(schema), silent = TRUE)
  if (!inherits(parsed, "try-error") && parsed$type %in% c("fixed_size_binary", "binary")) {
    return(rducks_arrow_uuid_array(values, schema))
  }
  nanoarrow::as_nanoarrow_array(as.character(values), schema = schema)
}

rducks_arrow_scalar_values_to_array.rducks_interval_type <- function(type, results, schema) {
  rducks_arrow_interval_array(results, schema)
}

rducks_arrow_scalar_values_to_array.rducks_bit_type <- function(type, results, schema) {
  rducks_arrow_bit_array(results, schema)
}

rducks_arrow_scalar_values_to_array.rducks_blob_type <- function(type, results, schema) {
  nanoarrow::as_nanoarrow_array(results, schema = schema)
}

rducks_arrow_scalar_values_to_array.rducks_scalar_type <- function(type, results, schema) {
  nanoarrow::as_nanoarrow_array(results, schema = schema)
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
    storage <- vapply(chars, rducks_arrow_decimal_storage_string, character(1), scale = params$scale)
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
        flat[pos] <- list(if (inherits(value, "rducks_decimal") || inherits(value, "rducks_interval")) value[j] else value[[j]])
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
        flat[pos] <- list(if (inherits(value, "rducks_decimal") || inherits(value, "rducks_interval")) value[j] else value[[j]])
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

  # MAP is delegated to nanoarrow's schema-guided constructor. This keeps the
  # native path Arrow-based while the R adapter normalizes row objects.
  prepared <- results
  if (inherits(type, "rducks_map_type")) {
    prepared <- lapply(results, function(x) {
      if (is.null(x)) return(NULL)
      data.frame(key = I(x$keys), value = I(x$values))
    })
  }
  nanoarrow::as_nanoarrow_array(prepared, schema = schema)
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

rducks_make_arrow_row_wrapper <- function(fun, spec, null_handling, exception_handling) {
  arg_types <- spec$arg_types
  return_type <- spec$return_type
  force(fun)
  force(arg_types)
  force(return_type)
  force(null_handling)
  force(exception_handling)

  function(input_array, input_schema, output_schema, n) {
    tryCatch({
      n <- as.integer(n)
      if (!nanoarrow::nanoarrow_pointer_is_valid(input_array)) {
        stop("input Arrow array is not valid", call. = FALSE)
      }
      if (!nanoarrow::nanoarrow_pointer_is_valid(input_schema)) {
        stop("input Arrow schema is not valid", call. = FALSE)
      }
      if (!nanoarrow::nanoarrow_pointer_is_valid(output_schema)) {
        stop("output Arrow schema is not valid", call. = FALSE)
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

    results <- vector("list", n)
    for (row in seq_len(n)) {
      if (isTRUE(top_level_null[[row]]) && identical(null_handling, "default")) {
        results[row] <- list(NULL)
        next
      }

      args <- vector("list", length(arg_types))
      for (col in seq_along(arg_types)) {
        args[col] <- list(rducks_arrow_value_at(arg_types[[col]], columns[[col]], nulls[[col]], row))
      }

      value <- tryCatch(
        do.call(fun, args),
        error = function(e) {
          if (identical(exception_handling, "return_null")) {
            return(structure(list(), class = "rducks_arrow_return_null"))
          }
          stop(e)
        }
      )
      if (inherits(value, "rducks_arrow_return_null")) {
        results[row] <- list(NULL)
      } else {
        if (!inherits(return_type, "rducks_decimal_type")) {
          rducks_check_return(return_type, value)
        }
        results[row] <- list(value)
      }
    }

      rducks_arrow_result_array(return_type, results, output_schema, n)
    }, error = function(e) {
      msg <- paste0("Rducks Arrow callback or marshal error: ", conditionMessage(e))
      .rducks_state$last_arrow_error <- msg
      stop(msg, call. = FALSE)
    })
  }
}
