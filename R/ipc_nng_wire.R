rducks_nng_wire_magic <- charToRaw("RDK1")
rducks_nng_wire_version <- 1L
rducks_nng_wire_type_execute <- 1L
rducks_nng_wire_type_register <- 2L
rducks_nng_wire_type_stop <- 3L
rducks_nng_wire_type_ping <- 4L
rducks_nng_wire_type_response <- 100L

rducks_nng_wire_u32 <- function(x) {
  writeBin(as.integer(x), raw(), size = 4L, endian = "little")
}

rducks_nng_wire_u64 <- function(x) {
  x <- as.numeric(x)
  if (length(x) != 1L || is.na(x) || !is.finite(x) || x < 0 || x >= 2^53) {
    stop("NNG wire uint64 value is out of range", call. = FALSE)
  }
  lo <- x %% 2^32
  hi <- floor(x / 2^32)
  c(rducks_nng_wire_u32(lo), rducks_nng_wire_u32(hi))
}

rducks_nng_wire_read_u32 <- function(buf, pos) {
  bytes <- as.integer(buf[pos:(pos + 3L)])
  value <- bytes[[1L]] + bytes[[2L]] * 256 + bytes[[3L]] * 65536 + bytes[[4L]] * 16777216
  list(value = value, pos = pos + 4L)
}

rducks_nng_wire_read_u64 <- function(buf, pos) {
  lo <- rducks_nng_wire_read_u32(buf, pos)
  hi <- rducks_nng_wire_read_u32(buf, lo$pos)
  list(value = lo$value + hi$value * 2^32, pos = hi$pos)
}

rducks_nng_wire_check_magic <- function(buf) {
  length(buf) >= 4L && identical(as.raw(buf[1:4]), rducks_nng_wire_magic)
}

rducks_nng_wire_encode_request <- function(type, udf_id = "", row_count = 0, payload = raw()) {
  if (!is.raw(payload)) stop("NNG wire payload must be raw", call. = FALSE)
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
  if (!is.raw(buf) || length(buf) < 32L || !rducks_nng_wire_check_magic(buf)) {
    stop("invalid Rducks NNG request frame", call. = FALSE)
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
  total <- 36 + udf_len$value + payload_len$value
  if (total != length(buf)) stop("truncated Rducks NNG request frame", call. = FALSE)
  udf_id <- if (udf_len$value > 0) rawToChar(buf[pos:(pos + udf_len$value - 1L)]) else ""
  pos <- pos + udf_len$value
  payload <- if (payload_len$value > 0) as.raw(buf[pos:(pos + payload_len$value - 1L)]) else raw()
  list(
    type = as.integer(type$value),
    udf_id = udf_id,
    row_count = as.integer(row_count$value),
    payload = payload
  )
}

rducks_nng_wire_encode_response <- function(status = "ok", payload = raw(), error = "") {
  if (!is.raw(payload)) stop("NNG wire payload must be raw", call. = FALSE)
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
  if (!is.raw(buf) || length(buf) < 32L || !rducks_nng_wire_check_magic(buf)) {
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
  total <- 32 + error_len$value + payload_len$value
  if (total != length(buf)) stop("truncated Rducks NNG response frame", call. = FALSE)
  error <- if (error_len$value > 0) rawToChar(buf[pos:(pos + error_len$value - 1L)]) else ""
  pos <- pos + error_len$value
  payload <- if (payload_len$value > 0) as.raw(buf[pos:(pos + payload_len$value - 1L)]) else raw()
  list(status = if (status$value == 0) "ok" else "error", error = error, payload = payload)
}
