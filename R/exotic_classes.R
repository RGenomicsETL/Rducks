rducks_normalize_integer_string <- function(x, unsigned = FALSE, what = "integer") {
  if (is.numeric(x) || is.integer(x)) {
    x <- as.numeric(x)
    out <- rep(NA_character_, length(x))
    missing <- is.na(x)
    bad <- !missing & (!is.finite(x) | x != trunc(x))
    if (any(bad)) {
      stop(what, " values must be whole finite numbers or integer strings", call. = FALSE)
    }
    too_large <- !missing & abs(x) >= 2^53
    if (any(too_large)) {
      stop(what, " numeric values at or outside +/-2^53 must be supplied as character strings", call. = FALSE)
    }
    out[!missing] <- format(x[!missing], scientific = FALSE, trim = TRUE)
    x <- out
  } else {
    x <- as.character(x)
  }

  out <- trimws(x)
  missing <- is.na(out)
  if (any(!missing & !grepl("^[+-]?[0-9]+$", out))) {
    stop(what, " values must be integer strings", call. = FALSE)
  }
  negative <- !missing & startsWith(out, "-")
  if (unsigned && any(negative)) {
    stop(what, " values must be unsigned", call. = FALSE)
  }

  normalize_one <- function(value) {
    if (is.na(value)) return(NA_character_)
    sign <- ""
    if (startsWith(value, "+")) value <- substring(value, 2L)
    if (startsWith(value, "-")) {
      sign <- "-"
      value <- substring(value, 2L)
    }
    value <- sub("^0+", "", value)
    if (!nzchar(value)) return("0")
    paste0(sign, value)
  }
  vapply(out, normalize_one, character(1), USE.NAMES = FALSE)
}

rducks_check_integer_bounds <- function(x, min, max, what) {
  too_low <- !is.na(x) & rducks_compare_integer_strings(x, rep(min, length.out = length(x))) < 0L
  too_high <- !is.na(x) & rducks_compare_integer_strings(x, rep(max, length.out = length(x))) > 0L
  if (any(too_low | too_high)) {
    stop(what, " values are outside the supported range", call. = FALSE)
  }
  x
}

#' Construct exact DuckDB BIGINT values
#'
#' Values are stored as canonical decimal strings so signed 64-bit values are
#' not silently rounded through R double.
#'
#' @param x Numeric, integer, or character vector of whole numbers.
#' @return Character vector with class `rducks_bigint`.
#' @export
rducks_bigint <- function(x = character()) {
  value <- rducks_normalize_integer_string(x, unsigned = FALSE, what = "BIGINT")
  value <- rducks_check_integer_bounds(value, "-9223372036854775808", "9223372036854775807", "BIGINT")
  structure(value, class = c("rducks_bigint", "character"))
}

#' @export
format.rducks_bigint <- function(x, ...) unclass(x)

#' @export
as.character.rducks_bigint <- function(x, ...) unclass(x)

#' @export
c.rducks_bigint <- function(..., recursive = FALSE) {
  rducks_bigint(unlist(lapply(list(...), as.character), use.names = FALSE))
}

#' @export
`[.rducks_bigint` <- function(x, i, ...) rducks_bigint(unclass(x)[i])

#' @export
print.rducks_bigint <- function(x, ...) {
  cat("<rducks_bigint[", length(x), "]>\n", sep = "")
  print(unclass(x), quote = FALSE)
  invisible(x)
}

#' Construct exact DuckDB UBIGINT values
#'
#' Values are stored as canonical unsigned decimal strings.
#'
#' @param x Numeric, integer, or character vector of whole unsigned numbers.
#' @return Character vector with class `rducks_ubigint`.
#' @export
rducks_ubigint <- function(x = character()) {
  value <- rducks_normalize_integer_string(x, unsigned = TRUE, what = "UBIGINT")
  value <- rducks_check_integer_bounds(value, "0", "18446744073709551615", "UBIGINT")
  structure(value, class = c("rducks_ubigint", "character"))
}

#' @export
format.rducks_ubigint <- function(x, ...) unclass(x)

#' @export
as.character.rducks_ubigint <- function(x, ...) unclass(x)

#' @export
c.rducks_ubigint <- function(..., recursive = FALSE) {
  rducks_ubigint(unlist(lapply(list(...), as.character), use.names = FALSE))
}

#' @export
`[.rducks_ubigint` <- function(x, i, ...) rducks_ubigint(unclass(x)[i])

#' @export
print.rducks_ubigint <- function(x, ...) {
  cat("<rducks_ubigint[", length(x), "]>\n", sep = "")
  print(unclass(x), quote = FALSE)
  invisible(x)
}

#' Construct DuckDB UUID values
#'
#' `rducks_uuid()` stores canonical UUID text in a dedicated class. Native UDF
#' marshalling for DuckDB `UUID` is implemented separately from this value class.
#'
#' @param x Character vector of UUID strings.
#' @return Character vector with class `rducks_uuid`.
#' @export
rducks_uuid <- function(x = character()) {
  x <- tolower(trimws(as.character(x)))
  ok <- is.na(x) | grepl("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", x)
  if (!all(ok)) {
    stop("UUID values must use canonical 8-4-4-4-12 hexadecimal form", call. = FALSE)
  }
  structure(x, class = c("rducks_uuid", "character"))
}

#' @export
format.rducks_uuid <- function(x, ...) unclass(x)

#' @export
as.character.rducks_uuid <- function(x, ...) unclass(x)

#' @export
c.rducks_uuid <- function(..., recursive = FALSE) {
  rducks_uuid(unlist(lapply(list(...), as.character), use.names = FALSE))
}

#' @export
`[.rducks_uuid` <- function(x, i, ...) rducks_uuid(unclass(x)[i])

#' @export
print.rducks_uuid <- function(x, ...) {
  cat("<rducks_uuid[", length(x), "]>\n", sep = "")
  print(unclass(x), quote = FALSE)
  invisible(x)
}

#' Construct exact DuckDB HUGEINT values
#'
#' Values are stored as canonical decimal strings so values outside R's exact
#' numeric range are not silently rounded.
#'
#' @param x Numeric, integer, or character vector of whole numbers.
#' @return Character vector with class `rducks_hugeint`.
#' @export
rducks_hugeint <- function(x = character()) {
  value <- rducks_normalize_integer_string(x, unsigned = FALSE, what = "HUGEINT")
  value <- rducks_check_integer_bounds(
    value,
    "-170141183460469231731687303715884105728",
    "170141183460469231731687303715884105727",
    "HUGEINT"
  )
  structure(value, class = c("rducks_hugeint", "character"))
}

#' @export
format.rducks_hugeint <- function(x, ...) unclass(x)

#' @export
as.character.rducks_hugeint <- function(x, ...) unclass(x)

#' @export
c.rducks_hugeint <- function(..., recursive = FALSE) {
  rducks_hugeint(unlist(lapply(list(...), as.character), use.names = FALSE))
}

#' @export
`[.rducks_hugeint` <- function(x, i, ...) rducks_hugeint(unclass(x)[i])

#' @export
print.rducks_hugeint <- function(x, ...) {
  cat("<rducks_hugeint[", length(x), "]>\n", sep = "")
  print(unclass(x), quote = FALSE)
  invisible(x)
}

#' Construct exact DuckDB UHUGEINT values
#'
#' Values are stored as canonical unsigned decimal strings.
#'
#' @param x Numeric, integer, or character vector of whole unsigned numbers.
#' @return Character vector with class `rducks_uhugeint`.
#' @export
rducks_uhugeint <- function(x = character()) {
  value <- rducks_normalize_integer_string(x, unsigned = TRUE, what = "UHUGEINT")
  value <- rducks_check_integer_bounds(
    value,
    "0",
    "340282366920938463463374607431768211455",
    "UHUGEINT"
  )
  structure(value, class = c("rducks_uhugeint", "character"))
}

#' @export
format.rducks_uhugeint <- function(x, ...) unclass(x)

#' @export
as.character.rducks_uhugeint <- function(x, ...) unclass(x)

#' @export
c.rducks_uhugeint <- function(..., recursive = FALSE) {
  rducks_uhugeint(unlist(lapply(list(...), as.character), use.names = FALSE))
}

#' @export
`[.rducks_uhugeint` <- function(x, i, ...) rducks_uhugeint(unclass(x)[i])

#' @export
print.rducks_uhugeint <- function(x, ...) {
  cat("<rducks_uhugeint[", length(x), "]>\n", sep = "")
  print(unclass(x), quote = FALSE)
  invisible(x)
}

rducks_check_decimal_spec <- function(width, scale) {
  if (!is.numeric(width) || length(width) != 1L || is.na(width) || width != as.integer(width) || width < 1L || width > 38L) {
    stop("width must be an integer from 1 to 38", call. = FALSE)
  }
  if (!is.numeric(scale) || length(scale) != 1L || is.na(scale) || scale != as.integer(scale) || scale < 0L || scale > width) {
    stop("scale must be an integer from 0 to width", call. = FALSE)
  }
  c(width = as.integer(width), scale = as.integer(scale))
}

rducks_normalize_decimal_string <- function(x, width, scale) {
  if (is.numeric(x) || is.integer(x)) {
    x <- format(as.numeric(x), scientific = FALSE, trim = TRUE, digits = 17L)
  } else {
    x <- as.character(x)
  }
  out <- trimws(x)
  missing <- is.na(out)
  if (any(!missing & !grepl("^[+-]?([0-9]+)(\\.[0-9]+)?$", out))) {
    stop("DECIMAL values must be fixed-point decimal strings", call. = FALSE)
  }
  normalize_one <- function(value) {
    if (is.na(value)) return(NA_character_)
    sign <- ""
    if (startsWith(value, "+")) value <- substring(value, 2L)
    if (startsWith(value, "-")) {
      sign <- "-"
      value <- substring(value, 2L)
    }
    parts <- strsplit(value, ".", fixed = TRUE)[[1L]]
    int <- parts[[1L]]
    frac <- if (length(parts) == 2L) parts[[2L]] else ""
    if (nchar(frac) > scale) {
      stop("DECIMAL value has more fractional digits than scale", call. = FALSE)
    }
    int_norm <- sub("^0+", "", int)
    if (!nzchar(int_norm)) int_norm <- "0"
    significant_digits <- nchar(int_norm) + max(nchar(frac), scale)
    if (identical(int_norm, "0")) {
      significant_digits <- max(1L, max(nchar(frac), scale))
    }
    if (significant_digits > width) {
      stop("DECIMAL value exceeds declared width", call. = FALSE)
    }
    frac <- paste0(frac, strrep("0", scale - nchar(frac)))
    if (scale > 0L) paste0(sign, int_norm, ".", frac) else paste0(sign, int_norm)
  }
  vapply(out, normalize_one, character(1), USE.NAMES = FALSE)
}

#' Construct exact DuckDB DECIMAL values
#'
#' Values are stored as fixed-point character data plus a declared width and
#' scale. This avoids silently rounding exact decimal values through R double.
#'
#' @param x Numeric, integer, or character vector of fixed-point decimal values.
#' @param width DuckDB decimal width, from 1 to 38.
#' @param scale DuckDB decimal scale, from 0 to `width`.
#' @return Object of class `rducks_decimal`.
#' @export
rducks_decimal <- function(x = character(), width, scale = 0L) {
  spec <- rducks_check_decimal_spec(width, scale)
  value <- rducks_normalize_decimal_string(x, spec[["width"]], spec[["scale"]])
  structure(
    list(value = value, width = spec[["width"]], scale = spec[["scale"]]),
    class = "rducks_decimal"
  )
}

#' @export
length.rducks_decimal <- function(x) length(x$value)

#' @export
`[.rducks_decimal` <- function(x, i, ...) {
  structure(list(value = x$value[i], width = x$width, scale = x$scale), class = "rducks_decimal")
}

#' @export
as.character.rducks_decimal <- function(x, ...) x$value

#' @export
c.rducks_decimal <- function(..., recursive = FALSE) {
  values <- list(...)
  if (!length(values)) return(rducks_decimal(character(), width = 1L, scale = 0L))
  first <- values[[1L]]
  if (!inherits(first, "rducks_decimal")) stop("first value must be a rducks_decimal", call. = FALSE)
  values <- lapply(values, function(value) {
    if (inherits(value, "rducks_decimal")) {
      if (!identical(value$width, first$width) || !identical(value$scale, first$scale)) {
        stop("all rducks_decimal values must have matching width and scale", call. = FALSE)
      }
      value$value
    } else {
      rducks_decimal(value, width = first$width, scale = first$scale)$value
    }
  })
  rducks_decimal(unlist(values, use.names = FALSE), width = first$width, scale = first$scale)
}

#' @export
format.rducks_decimal <- function(x, ...) x$value

#' @export
print.rducks_decimal <- function(x, ...) {
  cat("<rducks_decimal[", length(x), "] DECIMAL(", x$width, ", ", x$scale, ")>\n", sep = "")
  print(x$value, quote = FALSE)
  invisible(x)
}

#' Construct DuckDB INTERVAL values
#'
#' DuckDB intervals have three independent components: months, days, and
#' microseconds. This class preserves those components instead of collapsing an
#' interval to a single duration.
#'
#' @param months Integer month components.
#' @param days Integer day components.
#' @param micros Integer microsecond components. Values outside R's exact
#'   numeric range should be supplied as character strings.
#' @return Object of class `rducks_interval`.
#' @export
rducks_interval <- function(months = 0L, days = 0L, micros = 0L) {
  n <- max(length(months), length(days), length(micros))
  months <- rep(months, length.out = n)
  days <- rep(days, length.out = n)
  micros <- rep(micros, length.out = n)
  if (any(!is.na(months) & (months != trunc(months) | months < -2147483648 | months > 2147483647))) {
    stop("months must fit in signed 32-bit integers", call. = FALSE)
  }
  if (any(!is.na(days) & (days != trunc(days) | days < -2147483648 | days > 2147483647))) {
    stop("days must fit in signed 32-bit integers", call. = FALSE)
  }
  micros <- rducks_normalize_integer_string(micros, unsigned = FALSE, what = "INTERVAL micros")
  micros <- rducks_check_integer_bounds(micros, "-9223372036854775808", "9223372036854775807", "INTERVAL micros")
  structure(
    list(
      months = as.integer(months),
      days = as.integer(days),
      micros = micros
    ),
    class = "rducks_interval"
  )
}

#' @export
length.rducks_interval <- function(x) length(x$months)

#' @export
`[.rducks_interval` <- function(x, i, ...) {
  structure(list(months = x$months[i], days = x$days[i], micros = x$micros[i]), class = "rducks_interval")
}

#' @export
as.character.rducks_interval <- function(x, ...) {
  sprintf("%s months %s days %s micros", x$months, x$days, x$micros)
}

#' @export
c.rducks_interval <- function(..., recursive = FALSE) {
  values <- lapply(list(...), function(value) {
    if (!inherits(value, "rducks_interval")) stop("all values must be rducks_interval objects", call. = FALSE)
    value
  })
  rducks_interval(
    months = unlist(lapply(values, `[[`, "months"), use.names = FALSE),
    days = unlist(lapply(values, `[[`, "days"), use.names = FALSE),
    micros = unlist(lapply(values, `[[`, "micros"), use.names = FALSE)
  )
}

#' @export
as.data.frame.rducks_interval <- function(x, row.names = NULL, optional = FALSE, ...) {
  data.frame(months = x$months, days = x$days, micros = x$micros, row.names = row.names)
}

#' @export
print.rducks_interval <- function(x, ...) {
  cat("<rducks_interval[", length(x), "]>\n", sep = "")
  print(as.data.frame(x), row.names = FALSE)
  invisible(x)
}

rducks_interval_arith <- function(e1, e2, op) {
  if (!inherits(e1, "rducks_interval")) stop("interval arithmetic requires rducks_interval objects", call. = FALSE)
  if (missing(e2)) {
    if (op == "+") return(e1)
    if (op == "-") {
      return(rducks_interval(
        months = -e1$months,
        days = -e1$days,
        micros = rducks_integer_negate_strings(e1$micros)
      ))
    }
    stop("operation ", op, " is not implemented for rducks_interval", call. = FALSE)
  }
  if (!inherits(e2, "rducks_interval")) stop("interval arithmetic requires rducks_interval objects", call. = FALSE)
  n <- max(length(e1), length(e2))
  months <- rep(e1$months, length.out = n)
  days <- rep(e1$days, length.out = n)
  micros <- rep(e1$micros, length.out = n)
  rhs_months <- rep(e2$months, length.out = n)
  rhs_days <- rep(e2$days, length.out = n)
  rhs_micros <- rep(e2$micros, length.out = n)
  if (op == "-") {
    rhs_months <- -rhs_months
    rhs_days <- -rhs_days
    rhs_micros <- rducks_integer_negate_strings(rhs_micros)
  }
  rducks_interval(
    months = months + rhs_months,
    days = days + rhs_days,
    micros = rducks_integer_add_strings(micros, rhs_micros)
  )
}

#' @export
Ops.rducks_interval <- function(e1, e2) {
  if (.Generic %in% c("+", "-")) {
    if (missing(e2)) return(rducks_interval_arith(e1, op = .Generic))
    return(rducks_interval_arith(e1, e2, .Generic))
  }
  stop("operation ", .Generic, " is not implemented for rducks_interval", call. = FALSE)
}

rducks_pack_bits <- function(bits) {
  n <- length(bits)
  out <- raw(ceiling(n / 8))
  for (i in seq_len(n)) {
    if (isTRUE(bits[[i]] != 0L)) {
      byte <- (i - 1L) %/% 8L + 1L
      shift <- 7L - ((i - 1L) %% 8L)
      out[[byte]] <- as.raw(bitwOr(as.integer(out[[byte]]), bitwShiftL(1L, shift)))
    }
  }
  out
}

rducks_unpack_bits <- function(data, bit_length) {
  if (bit_length == 0L) return(integer())
  out <- integer(bit_length)
  for (i in seq_len(bit_length)) {
    byte <- (i - 1L) %/% 8L + 1L
    shift <- 7L - ((i - 1L) %% 8L)
    out[[i]] <- bitwAnd(bitwShiftR(as.integer(data[[byte]]), shift), 1L)
  }
  out
}

#' Construct DuckDB BIT values
#'
#' `rducks_bits()` stores bits as packed raw bytes plus an explicit bit length.
#' Bits are packed left-to-right, with the first bit in the high bit of the
#' first byte.
#'
#' @param x Character string of `0`/`1`, logical/integer bit vector, raw bytes,
#'   or another `rducks_bits` object.
#' @param length Optional bit length when `x` is raw.
#' @return Object of class `rducks_bits`.
#' @export
rducks_bits <- function(x = raw(), length = NULL) {
  if (inherits(x, "rducks_bits")) return(x)
  if (is.raw(x)) {
    bit_length <- if (is.null(length)) base::length(x) * 8L else as.integer(length)
    if (is.na(bit_length) || bit_length <= 0L || bit_length > base::length(x) * 8L) {
      stop("length must be between 1 and the raw storage bit capacity", call. = FALSE)
    }
    return(structure(list(data = x, length = bit_length), class = "rducks_bits"))
  }
  if (is.character(x)) {
    if (length(x) != 1L || is.na(x)) stop("character BIT input must be a single non-NA string", call. = FALSE)
    chars <- strsplit(gsub("[[:space:]_]+", "", x), "", fixed = TRUE)[[1L]]
    if (length(chars) && any(!chars %in% c("0", "1"))) {
      stop("BIT character input may contain only 0 and 1", call. = FALSE)
    }
    bits <- as.integer(chars)
  } else {
    bits <- as.integer(x)
    if (any(is.na(bits)) || any(!bits %in% c(0L, 1L))) {
      stop("BIT vector input must contain only 0/1 or TRUE/FALSE values", call. = FALSE)
    }
  }
  if (!length(bits)) {
    stop("BIT values must contain at least one bit", call. = FALSE)
  }
  structure(list(data = rducks_pack_bits(bits), length = length(bits)), class = "rducks_bits")
}

#' @export
as.character.rducks_bits <- function(x, ...) paste0(rducks_unpack_bits(x$data, x$length), collapse = "")

#' @export
format.rducks_bits <- function(x, ...) as.character(x)

#' @export
as.integer.rducks_bits <- function(x, ...) rducks_unpack_bits(x$data, x$length)

#' @export
as.logical.rducks_bits <- function(x, ...) as.logical(as.integer(x))

#' @export
as.raw.rducks_bits <- function(x) rducks_bits_raw(x)

#' @export
c.rducks_bits <- function(..., recursive = FALSE) {
  bits <- unlist(lapply(list(...), function(value) as.integer(rducks_bits(value))), use.names = FALSE)
  rducks_bits(bits)
}

#' @export
print.rducks_bits <- function(x, ...) {
  cat("<rducks_bits[", x$length, "] ", as.character(x), ">\n", sep = "")
  invisible(x)
}

#' @rdname rducks_bits
#' @export
rducks_bits_raw <- function(x) {
  if (!inherits(x, "rducks_bits")) stop("x must be a rducks_bits object", call. = FALSE)
  x$data
}

#' Construct DuckDB ENUM values
#'
#' `rducks_enum()` stores values as a factor with an additional class so the
#' DuckDB enum dictionary is explicit.
#'
#' @param x Character vector or factor of enum values.
#' @param levels Character vector of allowed enum dictionary values. If `x` is a
#'   factor and `levels` is omitted, the factor levels are used.
#' @return Factor with class `rducks_enum`.
#' @export
rducks_enum <- function(x, levels = NULL) {
  if (is.factor(x) && is.null(levels)) levels <- levels(x)
  if (is.null(levels) || !is.character(levels) || anyNA(levels) || any(!nzchar(levels))) {
    stop("levels must be a non-empty character vector without missing values", call. = FALSE)
  }
  out <- factor(as.character(x), levels = levels, exclude = NULL)
  bad <- !is.na(x) & is.na(out)
  if (any(bad)) {
    stop("enum values must be present in levels", call. = FALSE)
  }
  class(out) <- c("rducks_enum", class(out))
  out
}

#' @export
as.character.rducks_enum <- function(x, ...) as.character(structure(unclass(x), levels = levels(x), class = "factor"))

#' @export
c.rducks_enum <- function(..., recursive = FALSE) {
  values <- list(...)
  if (!length(values)) stop("at least one rducks_enum value is required", call. = FALSE)
  first <- values[[1L]]
  if (!inherits(first, "rducks_enum")) stop("first value must be a rducks_enum", call. = FALSE)
  out <- lapply(values, function(value) {
    if (inherits(value, "rducks_enum")) {
      if (!identical(levels(value), levels(first))) {
        stop("all rducks_enum values must have matching levels", call. = FALSE)
      }
      as.character(value)
    } else {
      as.character(value)
    }
  })
  rducks_enum(unlist(out, use.names = FALSE), levels = levels(first))
}

#' @export
print.rducks_enum <- function(x, ...) {
  cat("<rducks_enum[", length(x), "] levels=", paste(levels(x), collapse = ","), ">\n", sep = "")
  base_factor <- structure(unclass(x), levels = levels(x), class = "factor")
  print(base_factor, quote = FALSE)
  invisible(x)
}

#' Construct DuckDB UNION values
#'
#' `rducks_union()` represents one tagged union value. The tag should match a
#' DuckDB union member name; `value` is the corresponding R value.
#'
#' @param tag Character scalar union member name.
#' @param value R value for that member.
#' @return Object of class `rducks_union`.
#' @export
rducks_union <- function(tag, value) {
  if (!is.character(tag) || length(tag) != 1L || is.na(tag) || !nzchar(tag)) {
    stop("tag must be a non-empty character scalar", call. = FALSE)
  }
  structure(list(tag = tag, value = value), class = "rducks_union")
}

#' @export
as.character.rducks_union <- function(x, ...) paste0(x$tag, ":", paste(utils::capture.output(utils::str(x$value, give.attr = FALSE)), collapse = " "))

#' @export
c.rducks_union <- function(..., recursive = FALSE) {
  out <- list(...)
  if (!all(vapply(out, inherits, logical(1), what = "rducks_union"))) {
    stop("all values must be rducks_union objects", call. = FALSE)
  }
  class(out) <- c("rducks_union_list", "list")
  out
}

#' @export
print.rducks_union_list <- function(x, ...) {
  cat("<rducks_union_list[", length(x), "]>\n", sep = "")
  for (i in seq_along(x)) {
    cat("  ", i, ": tag=", x[[i]]$tag, "\n", sep = "")
  }
  invisible(x)
}

#' @export
print.rducks_union <- function(x, ...) {
  cat("<rducks_union tag=", x$tag, ">\n", sep = "")
  print(x$value)
  invisible(x)
}

#' Generic helpers for Rducks value classes
#'
#' These helpers provide a small common interface for Rducks' exact value
#' classes used to represent DuckDB-specific values before native UDF marshalling
#' for those types is enabled.
#'
#' @param x A value object.
#' @param ... Reserved for methods.
#' @return `rducks_value_type()` returns a DuckDB type string.
#' @export
rducks_value_type <- function(x, ...) UseMethod("rducks_value_type")

#' @export
rducks_value_type.default <- function(x, ...) {
  stop("no Rducks DuckDB type mapping for objects of class: ", paste(class(x), collapse = ", "), call. = FALSE)
}

#' @rdname rducks_value_type
#' @export
rducks_duckdb_literal <- function(x, ...) UseMethod("rducks_duckdb_literal")

#' @export
rducks_duckdb_literal.default <- function(x, ...) {
  stop("no DuckDB literal method for objects of class: ", paste(class(x), collapse = ", "), call. = FALSE)
}

rducks_sql_quote <- function(x) paste0("'", gsub("'", "''", x, fixed = TRUE), "'")

rducks_scalar_literal_check <- function(x) {
  if (length(x) != 1L) stop("DuckDB literal conversion requires a scalar value", call. = FALSE)
  invisible(NULL)
}

#' @export
rducks_value_type.rducks_bigint <- function(x, ...) "BIGINT"

#' @export
rducks_duckdb_literal.rducks_bigint <- function(x, ...) {
  rducks_scalar_literal_check(x)
  if (is.na(x)) return("NULL::BIGINT")
  paste0(rducks_sql_quote(unclass(x)), "::BIGINT")
}

#' @export
rducks_value_type.rducks_ubigint <- function(x, ...) "UBIGINT"

#' @export
rducks_duckdb_literal.rducks_ubigint <- function(x, ...) {
  rducks_scalar_literal_check(x)
  if (is.na(x)) return("NULL::UBIGINT")
  paste0(rducks_sql_quote(unclass(x)), "::UBIGINT")
}

#' @export
rducks_value_type.rducks_uuid <- function(x, ...) "UUID"

#' @export
rducks_duckdb_literal.rducks_uuid <- function(x, ...) {
  rducks_scalar_literal_check(x)
  if (is.na(x)) return("NULL::UUID")
  paste0(rducks_sql_quote(unclass(x)), "::UUID")
}

#' @export
rducks_value_type.rducks_hugeint <- function(x, ...) "HUGEINT"

#' @export
rducks_duckdb_literal.rducks_hugeint <- function(x, ...) {
  rducks_scalar_literal_check(x)
  if (is.na(x)) return("NULL::HUGEINT")
  paste0(rducks_sql_quote(unclass(x)), "::HUGEINT")
}

#' @export
rducks_value_type.rducks_uhugeint <- function(x, ...) "UHUGEINT"

#' @export
rducks_duckdb_literal.rducks_uhugeint <- function(x, ...) {
  rducks_scalar_literal_check(x)
  if (is.na(x)) return("NULL::UHUGEINT")
  paste0(rducks_sql_quote(unclass(x)), "::UHUGEINT")
}

#' @export
rducks_value_type.rducks_decimal <- function(x, ...) sprintf("DECIMAL(%d, %d)", x$width, x$scale)

#' @export
rducks_duckdb_literal.rducks_decimal <- function(x, ...) {
  rducks_scalar_literal_check(x)
  if (is.na(x$value)) return(paste0("NULL::", rducks_value_type(x)))
  paste0(rducks_sql_quote(x$value), "::", rducks_value_type(x))
}

#' @export
rducks_value_type.rducks_interval <- function(x, ...) "INTERVAL"

#' @export
rducks_duckdb_literal.rducks_interval <- function(x, ...) {
  rducks_scalar_literal_check(x)
  if (is.na(x$months) || is.na(x$days) || is.na(x$micros)) return("NULL::INTERVAL")
  sprintf(
    "((INTERVAL '1 month' * %d) + (INTERVAL '1 day' * %d) + (INTERVAL '1 microsecond' * %s))",
    x$months, x$days, x$micros
  )
}

#' @export
rducks_value_type.rducks_bits <- function(x, ...) "BIT"

#' @export
rducks_duckdb_literal.rducks_bits <- function(x, ...) {
  paste0(rducks_sql_quote(as.character(x)), "::BIT")
}

#' @export
rducks_value_type.rducks_enum <- function(x, ...) {
  paste0("ENUM(", paste(vapply(levels(x), rducks_sql_quote, character(1)), collapse = ", "), ")")
}

#' @export
rducks_duckdb_literal.rducks_enum <- function(x, ...) {
  rducks_scalar_literal_check(x)
  if (is.na(x)) return(paste0("NULL::", rducks_value_type(x)))
  paste0(rducks_sql_quote(as.character(x)), "::", rducks_value_type(x))
}

#' @export
rducks_value_type.rducks_union <- function(x, ...) paste0("UNION member ", x$tag)

#' @export
rducks_duckdb_literal.rducks_union <- function(x, ...) {
  stop("DuckDB UNION literals require a declared union type and are not generated by rducks_duckdb_literal()", call. = FALSE)
}

#' @export
length.rducks_bits <- function(x) x$length

#' @export
`[.rducks_bits` <- function(x, i, ...) {
  bits <- rducks_unpack_bits(x$data, x$length)
  rducks_bits(bits[i])
}

rducks_compare_integer_one <- function(a, b) {
  if (is.na(a) || is.na(b)) return(NA_integer_)
  sa <- if (startsWith(a, "-")) -1L else 1L
  sb <- if (startsWith(b, "-")) -1L else 1L
  aa <- if (sa < 0L) substring(a, 2L) else a
  bb <- if (sb < 0L) substring(b, 2L) else b
  if (identical(aa, "0")) sa <- 1L
  if (identical(bb, "0")) sb <- 1L
  if (sa != sb) return(if (sa < sb) -1L else 1L)
  if (nchar(aa) != nchar(bb)) {
    out <- if (nchar(aa) < nchar(bb)) -1L else 1L
    return(out * sa)
  }
  if (aa == bb) return(0L)
  out <- if (aa < bb) -1L else 1L
  out * sa
}

rducks_compare_integer_strings <- function(a, b) {
  n <- max(length(a), length(b))
  a <- rep(a, length.out = n)
  b <- rep(b, length.out = n)
  vapply(seq_len(n), function(i) rducks_compare_integer_one(a[[i]], b[[i]]), integer(1))
}

rducks_strip_sign <- function(x) {
  sign <- if (startsWith(x, "-")) -1L else 1L
  digits <- if (sign < 0L) substring(x, 2L) else x
  list(sign = if (identical(digits, "0")) 1L else sign, digits = digits)
}

rducks_add_abs_integer <- function(a, b) {
  a <- strsplit(a, "", fixed = TRUE)[[1L]]
  b <- strsplit(b, "", fixed = TRUE)[[1L]]
  ia <- length(a)
  ib <- length(b)
  carry <- 0L
  out <- character()
  while (ia > 0L || ib > 0L || carry > 0L) {
    da <- if (ia > 0L) as.integer(a[[ia]]) else 0L
    db <- if (ib > 0L) as.integer(b[[ib]]) else 0L
    sum <- da + db + carry
    out <- c(as.character(sum %% 10L), out)
    carry <- sum %/% 10L
    ia <- ia - 1L
    ib <- ib - 1L
  }
  paste0(out, collapse = "")
}

rducks_sub_abs_integer <- function(a, b) {
  a_digits <- strsplit(a, "", fixed = TRUE)[[1L]]
  b_digits <- strsplit(b, "", fixed = TRUE)[[1L]]
  ia <- length(a_digits)
  ib <- length(b_digits)
  borrow <- 0L
  out <- character()
  while (ia > 0L) {
    da <- as.integer(a_digits[[ia]]) - borrow
    db <- if (ib > 0L) as.integer(b_digits[[ib]]) else 0L
    if (da < db) {
      da <- da + 10L
      borrow <- 1L
    } else {
      borrow <- 0L
    }
    out <- c(as.character(da - db), out)
    ia <- ia - 1L
    ib <- ib - 1L
  }
  result <- sub("^0+", "", paste0(out, collapse = ""))
  if (nzchar(result)) result else "0"
}

rducks_integer_add_one <- function(a, b) {
  if (is.na(a) || is.na(b)) return(NA_character_)
  pa <- rducks_strip_sign(a)
  pb <- rducks_strip_sign(b)
  if (pa$sign == pb$sign) {
    digits <- rducks_add_abs_integer(pa$digits, pb$digits)
    out <- if (pa$sign < 0L && !identical(digits, "0")) paste0("-", digits) else digits
    return(out)
  }
  cmp <- rducks_compare_integer_one(pa$digits, pb$digits)
  if (cmp == 0L) return("0")
  if (cmp > 0L) {
    digits <- rducks_sub_abs_integer(pa$digits, pb$digits)
    sign <- pa$sign
  } else {
    digits <- rducks_sub_abs_integer(pb$digits, pa$digits)
    sign <- pb$sign
  }
  if (sign < 0L && !identical(digits, "0")) paste0("-", digits) else digits
}

rducks_integer_add_strings <- function(a, b) {
  n <- max(length(a), length(b))
  a <- rep(a, length.out = n)
  b <- rep(b, length.out = n)
  vapply(seq_len(n), function(i) rducks_integer_add_one(a[[i]], b[[i]]), character(1))
}

rducks_integer_negate_strings <- function(x) {
  vapply(x, function(value) {
    if (is.na(value) || identical(value, "0")) return(value)
    if (startsWith(value, "-")) substring(value, 2L) else paste0("-", value)
  }, character(1), USE.NAMES = FALSE)
}

rducks_integer_arith <- function(e1, e2, op, unsigned = FALSE, what = "integer") {
  left <- rducks_normalize_integer_string(e1, unsigned = unsigned, what = what)
  if (missing(e2)) {
    if (op == "+") return(left)
    if (op == "-") {
      if (unsigned) stop("unary - is not valid for ", what, " values", call. = FALSE)
      return(rducks_integer_negate_strings(left))
    }
    stop("operation ", op, " is not implemented for ", what, " values", call. = FALSE)
  }
  right <- rducks_normalize_integer_string(e2, unsigned = unsigned, what = what)
  if (op == "-") right <- rducks_integer_negate_strings(right)
  out <- rducks_integer_add_strings(left, right)
  if (unsigned && any(!is.na(out) & startsWith(out, "-"))) {
    stop(what, " subtraction produced a negative value", call. = FALSE)
  }
  out
}

rducks_integer_double <- function(x, what) {
  values <- as.numeric(unclass(x))
  too_wide <- !is.na(unclass(x)) & nchar(gsub("^[+-]", "", unclass(x))) > 15L
  if (any(too_wide)) {
    warning(what, " converted through R double; precision may be lost", call. = FALSE)
  }
  values
}

#' @export
as.double.rducks_bigint <- function(x, ...) rducks_integer_double(x, "BIGINT")

#' @export
as.numeric.rducks_bigint <- function(x, ...) as.double.rducks_bigint(x, ...)

#' @export
as.integer.rducks_bigint <- function(x, ...) as.integer(as.double(x))

#' @export
as.double.rducks_ubigint <- function(x, ...) rducks_integer_double(x, "UBIGINT")

#' @export
as.numeric.rducks_ubigint <- function(x, ...) as.double.rducks_ubigint(x, ...)

#' @export
as.integer.rducks_ubigint <- function(x, ...) as.integer(as.double(x))

#' @export
as.double.rducks_hugeint <- function(x, ...) rducks_integer_double(x, "HUGEINT")

#' @export
as.numeric.rducks_hugeint <- function(x, ...) as.double.rducks_hugeint(x, ...)

#' @export
as.integer.rducks_hugeint <- function(x, ...) as.integer(as.double(x))

#' @export
as.double.rducks_uhugeint <- function(x, ...) rducks_integer_double(x, "UHUGEINT")

#' @export
as.numeric.rducks_uhugeint <- function(x, ...) as.double.rducks_uhugeint(x, ...)

#' @export
as.integer.rducks_uhugeint <- function(x, ...) as.integer(as.double(x))

rducks_integer_ops <- function(e1, e2, op, unsigned = FALSE, what = "integer") {
  left <- rducks_normalize_integer_string(e1, unsigned = unsigned, what = what)
  right <- rducks_normalize_integer_string(e2, unsigned = unsigned, what = what)
  cmp <- rducks_compare_integer_strings(left, right)
  switch(op,
    `==` = cmp == 0L,
    `!=` = cmp != 0L,
    `<` = cmp < 0L,
    `<=` = cmp <= 0L,
    `>` = cmp > 0L,
    `>=` = cmp >= 0L,
    stop("operation ", op, " is not implemented for ", what, " values", call. = FALSE)
  )
}

#' @export
Ops.rducks_bigint <- function(e1, e2) {
  if (.Generic %in% c("+", "-")) {
    if (missing(e2)) return(rducks_bigint(rducks_integer_arith(e1, op = .Generic, unsigned = FALSE, what = "BIGINT")))
    return(rducks_bigint(rducks_integer_arith(e1, e2, .Generic, unsigned = FALSE, what = "BIGINT")))
  }
  rducks_integer_ops(e1, e2, .Generic, unsigned = FALSE, what = "BIGINT")
}

#' @export
Ops.rducks_ubigint <- function(e1, e2) {
  if (.Generic %in% c("+", "-")) {
    if (missing(e2)) return(rducks_ubigint(rducks_integer_arith(e1, op = .Generic, unsigned = TRUE, what = "UBIGINT")))
    return(rducks_ubigint(rducks_integer_arith(e1, e2, .Generic, unsigned = TRUE, what = "UBIGINT")))
  }
  rducks_integer_ops(e1, e2, .Generic, unsigned = TRUE, what = "UBIGINT")
}

#' @export
Ops.rducks_hugeint <- function(e1, e2) {
  if (.Generic %in% c("+", "-")) {
    if (missing(e2)) return(rducks_hugeint(rducks_integer_arith(e1, op = .Generic, unsigned = FALSE, what = "HUGEINT")))
    return(rducks_hugeint(rducks_integer_arith(e1, e2, .Generic, unsigned = FALSE, what = "HUGEINT")))
  }
  rducks_integer_ops(e1, e2, .Generic, unsigned = FALSE, what = "HUGEINT")
}

#' @export
Ops.rducks_uhugeint <- function(e1, e2) {
  if (.Generic %in% c("+", "-")) {
    if (missing(e2)) return(rducks_uhugeint(rducks_integer_arith(e1, op = .Generic, unsigned = TRUE, what = "UHUGEINT")))
    return(rducks_uhugeint(rducks_integer_arith(e1, e2, .Generic, unsigned = TRUE, what = "UHUGEINT")))
  }
  rducks_integer_ops(e1, e2, .Generic, unsigned = TRUE, what = "UHUGEINT")
}

#' @export
as.double.rducks_decimal <- function(x, ...) {
  warning("DECIMAL converted through R double; exactness may be lost", call. = FALSE)
  as.numeric(x$value)
}

#' @export
as.numeric.rducks_decimal <- function(x, ...) as.double.rducks_decimal(x, ...)

#' @export
as.integer.rducks_decimal <- function(x, ...) as.integer(as.double(x))

rducks_decimal_scaled_integer <- function(x) {
  rducks_normalize_integer_string(gsub("\\.", "", x$value), unsigned = FALSE, what = "DECIMAL")
}

rducks_decimal_from_scaled_integer <- function(x, width, scale) {
  one <- function(value) {
    if (is.na(value)) return(NA_character_)
    sign <- ""
    if (startsWith(value, "-")) {
      sign <- "-"
      value <- substring(value, 2L)
    }
    value <- sub("^0+", "", value)
    if (!nzchar(value)) value <- "0"
    if (scale == 0L) return(paste0(sign, value))
    if (nchar(value) <= scale) {
      value <- paste0(strrep("0", scale - nchar(value) + 1L), value)
    }
    split <- nchar(value) - scale
    int <- substring(value, 1L, split)
    frac <- substring(value, split + 1L)
    paste0(sign, int, ".", frac)
  }
  rducks_decimal(vapply(x, one, character(1), USE.NAMES = FALSE), width = width, scale = scale)
}

rducks_decimal_arith <- function(e1, e2, op) {
  if (!inherits(e1, "rducks_decimal") && inherits(e2, "rducks_decimal")) {
    e1 <- rducks_decimal(e1, width = e2$width, scale = e2$scale)
  }
  if (inherits(e1, "rducks_decimal") && !missing(e2) && !inherits(e2, "rducks_decimal")) {
    e2 <- rducks_decimal(e2, width = e1$width, scale = e1$scale)
  }
  if (missing(e2)) {
    if (op == "+") return(e1)
    if (op == "-") {
      return(rducks_decimal_from_scaled_integer(rducks_integer_negate_strings(rducks_decimal_scaled_integer(e1)), e1$width, e1$scale))
    }
    stop("operation ", op, " is not implemented for rducks_decimal", call. = FALSE)
  }
  if (!identical(e1$scale, e2$scale)) {
    stop("decimal arithmetic requires matching scales", call. = FALSE)
  }
  right <- rducks_decimal_scaled_integer(e2)
  if (op == "-") right <- rducks_integer_negate_strings(right)
  width <- max(e1$width, e2$width) + 1L
  if (width > 38L) stop("DECIMAL arithmetic result width would exceed 38", call. = FALSE)
  rducks_decimal_from_scaled_integer(
    rducks_integer_add_strings(rducks_decimal_scaled_integer(e1), right),
    width = width,
    scale = e1$scale
  )
}

rducks_decimal_compare_values <- function(a, b) {
  if (!inherits(a, "rducks_decimal") || !inherits(b, "rducks_decimal")) {
    stop("decimal comparison requires rducks_decimal objects", call. = FALSE)
  }
  if (!identical(a$scale, b$scale)) {
    stop("decimal comparison requires matching scales", call. = FALSE)
  }
  ai <- gsub("\\.", "", a$value)
  bi <- gsub("\\.", "", b$value)
  rducks_compare_integer_strings(ai, bi)
}

#' @export
Ops.rducks_decimal <- function(e1, e2) {
  if (.Generic %in% c("+", "-")) {
    if (missing(e2)) return(rducks_decimal_arith(e1, op = .Generic))
    return(rducks_decimal_arith(e1, e2, .Generic))
  }
  if (!inherits(e1, "rducks_decimal") && inherits(e2, "rducks_decimal")) {
    e1 <- rducks_decimal(e1, width = e2$width, scale = e2$scale)
  }
  if (inherits(e1, "rducks_decimal") && !inherits(e2, "rducks_decimal")) {
    e2 <- rducks_decimal(e2, width = e1$width, scale = e1$scale)
  }
  cmp <- rducks_decimal_compare_values(e1, e2)
  switch(.Generic,
    `==` = cmp == 0L,
    `!=` = cmp != 0L,
    `<` = cmp < 0L,
    `<=` = cmp <= 0L,
    `>` = cmp > 0L,
    `>=` = cmp >= 0L,
    stop("operation ", .Generic, " is not implemented for rducks_decimal", call. = FALSE)
  )
}

rducks_bits_binary_op <- function(e1, e2, op) {
  e1 <- rducks_bits(e1)
  e2 <- rducks_bits(e2)
  if (length(e1) != length(e2)) stop("BIT operands must have the same bit length", call. = FALSE)
  a <- rducks_unpack_bits(e1$data, e1$length)
  b <- rducks_unpack_bits(e2$data, e2$length)
  out <- switch(op,
    `&` = bitwAnd(a, b),
    `|` = bitwOr(a, b),
    xor = bitwXor(a, b),
    stop("unsupported BIT operation", call. = FALSE)
  )
  rducks_bits(out)
}

#' BIT logical operations
#'
#' @param e1,e2 `rducks_bits` values, raw bytes, or 0/1 vectors.
#' @return `rducks_bits` for bitwise operations or logical values for equality.
#' @export
Ops.rducks_bits <- function(e1, e2) {
  if (.Generic %in% c("&", "|")) return(rducks_bits_binary_op(e1, e2, .Generic))
  if (.Generic %in% c("==", "!=")) {
    left <- as.character(rducks_bits(e1))
    right <- as.character(rducks_bits(e2))
    return(if (.Generic == "==") left == right else left != right)
  }
  stop("operation ", .Generic, " is not implemented for rducks_bits", call. = FALSE)
}

#' @rdname Ops.rducks_bits
#' @export
rducks_bits_xor <- function(e1, e2) rducks_bits_binary_op(e1, e2, "xor")

#' @export
`!.rducks_bits` <- function(x) {
  bits <- rducks_unpack_bits(x$data, x$length)
  rducks_bits(ifelse(bits == 0L, 1L, 0L))
}
