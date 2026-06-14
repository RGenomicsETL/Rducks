rducks_nng_wire_magic <- charToRaw("RDK1")
rducks_nng_dynamic_payload_magic <- charToRaw("RDT1")
rducks_nng_wire_version <- 1L
rducks_nng_wire_type_execute <- 1L
rducks_nng_wire_type_register <- 2L
rducks_nng_wire_type_stop <- 3L
rducks_nng_wire_type_ping <- 4L
rducks_nng_wire_type_response <- 100L
rducks_nng_wire_request_header_size <- 36L
rducks_nng_wire_response_header_size <- 32L
# R stores numeric wire lengths/counts as doubles. Keep the R-side u64 codec
# exact by accepting only values below 2^53; larger 64-bit values are rejected
# instead of being rounded silently.
rducks_nng_wire_u64_exact_limit <- 2^53
rducks_nng_dynamic_arg_count_limit <- 10000L

rducks_nng_wire_check_uint <- function(x, max_exclusive, what) {
  x <- as.numeric(x)
  if (length(x) != 1L || is.na(x) || !is.finite(x) || x < 0 || x >= max_exclusive || x != floor(x)) {
    stop("NNG wire ", what, " value is out of range", call. = FALSE)
  }
  x
}

rducks_nng_wire_check_pos <- function(pos) {
  pos <- as.numeric(pos)
  if (length(pos) != 1L || is.na(pos) || !is.finite(pos) || pos < 1L || pos != floor(pos)) {
    stop("truncated Rducks NNG frame", call. = FALSE)
  }
  pos
}

rducks_nng_wire_slice <- function(buf, pos, n, what = "Rducks NNG frame") {
  if (!is.raw(buf)) stop("invalid ", what, call. = FALSE)
  pos <- rducks_nng_wire_check_pos(pos)
  n <- rducks_nng_wire_check_uint(n, .Machine$integer.max + 1, "length")
  if (n == 0) return(raw())
  last <- pos + n - 1
  if (last > length(buf)) stop("truncated ", what, call. = FALSE)
  buf[seq.int(pos, last)]
}

rducks_nng_wire_u32 <- function(x) {
  x <- rducks_nng_wire_check_uint(x, 2^32, "uint32")
  as.raw(c(
    x %% 256,
    floor(x / 256) %% 256,
    floor(x / 65536) %% 256,
    floor(x / 16777216) %% 256
  ))
}

rducks_nng_wire_u64 <- function(x) {
  x <- rducks_nng_wire_check_uint(x, rducks_nng_wire_u64_exact_limit, "uint64")
  lo <- x %% 2^32
  hi <- floor(x / 2^32)
  c(rducks_nng_wire_u32(lo), rducks_nng_wire_u32(hi))
}

rducks_nng_wire_read_u32 <- function(buf, pos) {
  bytes <- as.integer(rducks_nng_wire_slice(buf, pos, 4L))
  value <- bytes[[1L]] + bytes[[2L]] * 256 + bytes[[3L]] * 65536 + bytes[[4L]] * 16777216
  list(value = value, pos = rducks_nng_wire_check_pos(pos) + 4L)
}

rducks_nng_wire_read_u64 <- function(buf, pos) {
  lo <- rducks_nng_wire_read_u32(buf, pos)
  hi <- rducks_nng_wire_read_u32(buf, lo$pos)
  value <- lo$value + hi$value * 2^32
  if (value >= rducks_nng_wire_u64_exact_limit) {
    stop("NNG wire uint64 value exceeds R's exact numeric range", call. = FALSE)
  }
  list(value = value, pos = hi$pos)
}

rducks_nng_wire_check_magic <- function(buf) {
  length(buf) >= 4L && identical(as.raw(buf[1:4]), rducks_nng_wire_magic)
}

rducks_nng_wire_decode_dynamic_payload <- function(payload) {
  if (!is.raw(payload) || length(payload) < 16L || !identical(as.raw(payload[1:4]), rducks_nng_dynamic_payload_magic)) {
    stop("invalid Rducks dynamic NNG payload", call. = FALSE)
  }
  pos <- 5L
  count <- rducks_nng_wire_read_u32(payload, pos); pos <- count$pos
  wire_len <- rducks_nng_wire_read_u64(payload, pos); pos <- wire_len$pos
  if (count$value > rducks_nng_dynamic_arg_count_limit) {
    stop("Rducks dynamic NNG payload has too many argument types", call. = FALSE)
  }
  tokens <- character(as.integer(count$value))
  for (i in seq_along(tokens)) {
    len <- rducks_nng_wire_read_u32(payload, pos); pos <- len$pos
    token_raw <- rducks_nng_wire_slice(payload, pos, len$value, "Rducks dynamic NNG payload")
    tokens[[i]] <- rawToChar(token_raw)
    pos <- rducks_nng_wire_check_pos(pos + len$value)
    if (pos > length(payload) + 1L) stop("truncated Rducks dynamic NNG payload", call. = FALSE)
  }
  wire_payload <- rducks_nng_wire_slice(payload, pos, wire_len$value, "Rducks dynamic NNG payload")
  pos <- rducks_nng_wire_check_pos(pos + wire_len$value)
  if (pos != length(payload) + 1L) {
    stop("truncated Rducks dynamic NNG payload", call. = FALSE)
  }
  list(payload = wire_payload, dynamic_arg_tokens = tokens)
}

rducks_nng_wire_encode_request <- function(type, udf_id = "", row_count = 0, payload = raw()) {
  if (!is.raw(payload)) stop("NNG wire payload must be raw", call. = FALSE)
  type <- as.integer(rducks_nng_wire_check_uint(type, 2^32, "request type"))
  if (!type %in% c(
    rducks_nng_wire_type_execute,
    rducks_nng_wire_type_register,
    rducks_nng_wire_type_stop,
    rducks_nng_wire_type_ping
  )) {
    stop("unsupported Rducks NNG request type", call. = FALSE)
  }
  if (!is.character(udf_id) || length(udf_id) != 1L || is.na(udf_id)) {
    stop("NNG wire UDF id must be a non-missing character scalar", call. = FALSE)
  }
  udf_raw <- charToRaw(enc2utf8(udf_id %||% ""))
  c(
    rducks_nng_wire_magic,
    rducks_nng_wire_u32(rducks_nng_wire_version),
    rducks_nng_wire_u32(type),
    rducks_nng_wire_u32(length(udf_raw)),
    rducks_nng_wire_u32(0L),
    rducks_nng_wire_u64(row_count),
    rducks_nng_wire_u64(length(payload)),
    udf_raw,
    payload
  )
}

rducks_nng_wire_decode_request <- function(buf) {
  if (!is.raw(buf) || !rducks_nng_wire_check_magic(buf)) {
    stop("invalid Rducks NNG request frame", call. = FALSE)
  }
  if (!is.finite(length(buf)) || length(buf) < rducks_nng_wire_request_header_size) {
    stop("truncated Rducks NNG request frame", call. = FALSE)
  }

  pos <- 5L
  version <- rducks_nng_wire_read_u32(buf, pos); pos <- version$pos
  type <- rducks_nng_wire_read_u32(buf, pos); pos <- type$pos
  udf_len <- rducks_nng_wire_read_u32(buf, pos); pos <- udf_len$pos
  reserved <- rducks_nng_wire_read_u32(buf, pos); pos <- reserved$pos
  row_count <- rducks_nng_wire_read_u64(buf, pos); pos <- row_count$pos
  payload_len <- rducks_nng_wire_read_u64(buf, pos); pos <- payload_len$pos
  if (!identical(as.integer(version$value), rducks_nng_wire_version)) {
    stop("unsupported Rducks NNG request version", call. = FALSE)
  }
  if (!(as.integer(type$value) %in% c(
    rducks_nng_wire_type_execute,
    rducks_nng_wire_type_register,
    rducks_nng_wire_type_stop,
    rducks_nng_wire_type_ping
  ))) {
    stop("unsupported Rducks NNG request type", call. = FALSE)
  }
  reserved_value <- as.integer(reserved$value)
  if (!reserved_value %in% c(0L, 1L)) {
    stop("invalid Rducks NNG request reserved field", call. = FALSE)
  }
  if (row_count$value > .Machine$integer.max) {
    stop("Rducks NNG request row count exceeds R integer range", call. = FALSE)
  }

  total <- rducks_nng_wire_request_header_size + udf_len$value + payload_len$value
  if (!is.finite(total) || total < rducks_nng_wire_request_header_size) {
    stop("invalid Rducks NNG request frame length", call. = FALSE)
  }
  if (total != length(buf)) {
    stop("truncated Rducks NNG request frame", call. = FALSE)
  }

  udf_id <- rawToChar(rducks_nng_wire_slice(buf, pos, udf_len$value, "Rducks NNG request frame"))
  pos <- pos + udf_len$value
  payload <- rducks_nng_wire_slice(buf, pos, payload_len$value, "Rducks NNG request frame")
  dynamic_arg_tokens <- NULL
  if (identical(reserved_value, 1L)) {
    dynamic <- rducks_nng_wire_decode_dynamic_payload(payload)
    payload <- dynamic$payload
    dynamic_arg_tokens <- dynamic$dynamic_arg_tokens
  }
  list(
    type = as.integer(type$value),
    udf_id = udf_id,
    row_count = as.integer(row_count$value),
    payload = payload,
    dynamic_arg_tokens = dynamic_arg_tokens
  )
}

rducks_nng_wire_encode_response <- function(status = "ok", payload = raw(), error = "") {
  if (!identical(status, "ok") && !identical(status, "error")) {
    stop("NNG wire response status must be 'ok' or 'error'", call. = FALSE)
  }
  if (!is.raw(payload)) stop("NNG wire payload must be raw", call. = FALSE)
  if (!is.character(error) || length(error) != 1L || is.na(error)) {
    stop("NNG wire response error must be a non-missing character scalar", call. = FALSE)
  }
  status_code <- if (identical(status, "ok")) 0L else 1L
  err_raw <- charToRaw(enc2utf8(error %||% ""))
  c(
    rducks_nng_wire_magic,
    rducks_nng_wire_u32(rducks_nng_wire_version),
    rducks_nng_wire_u32(rducks_nng_wire_type_response),
    rducks_nng_wire_u32(status_code),
    rducks_nng_wire_u32(length(err_raw)),
    rducks_nng_wire_u32(0L),
    rducks_nng_wire_u64(length(payload)),
    err_raw,
    payload
  )
}

rducks_nng_wire_decode_response <- function(buf) {
  if (!is.raw(buf) || !rducks_nng_wire_check_magic(buf)) {
    stop("invalid Rducks NNG response frame", call. = FALSE)
  }
  if (length(buf) < rducks_nng_wire_response_header_size) {
    stop("invalid Rducks NNG response frame", call. = FALSE)
  }
  pos <- 5L
  version <- rducks_nng_wire_read_u32(buf, pos); pos <- version$pos
  type <- rducks_nng_wire_read_u32(buf, pos); pos <- type$pos
  status <- rducks_nng_wire_read_u32(buf, pos); pos <- status$pos
  error_len <- rducks_nng_wire_read_u32(buf, pos); pos <- error_len$pos
  reserved <- rducks_nng_wire_read_u32(buf, pos); pos <- reserved$pos
  payload_len <- rducks_nng_wire_read_u64(buf, pos); pos <- payload_len$pos
  if (!identical(as.integer(version$value), rducks_nng_wire_version) ||
      !identical(as.integer(type$value), rducks_nng_wire_type_response)) {
    stop("unsupported Rducks NNG response frame", call. = FALSE)
  }
  if (!identical(as.integer(reserved$value), 0L) || !(as.integer(status$value) %in% c(0L, 1L))) {
    stop("invalid Rducks NNG response frame", call. = FALSE)
  }
  total <- rducks_nng_wire_response_header_size + error_len$value + payload_len$value
  if (!is.finite(total) || total < rducks_nng_wire_response_header_size) {
    stop("invalid Rducks NNG response frame length", call. = FALSE)
  }
  if (total != length(buf)) stop("truncated Rducks NNG response frame", call. = FALSE)
  error <- rawToChar(rducks_nng_wire_slice(buf, pos, error_len$value, "Rducks NNG response frame"))
  pos <- pos + error_len$value
  payload <- rducks_nng_wire_slice(buf, pos, payload_len$value, "Rducks NNG response frame")
  list(status = if (status$value == 0) "ok" else "error", error = error, payload = payload)
}
