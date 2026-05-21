rducks_normalize_integer_string <- function(x, unsigned = FALSE, what = "integer") {
  if (is.numeric(x) || is.integer(x)) {
    x <- as.numeric(x)
    out <- rep(NA_character_, length(x))
    nan <- is.nan(x)
    missing <- is.na(x) & !nan
    bad <- nan | (!missing & (!is.finite(x) | x != trunc(x)))
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
  .Call(RDUCKS_normalize_integer_string, x, isTRUE(unsigned), as.character(what)[[1L]])
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
#' @examples
#' rducks_bigint(1:3)
#' rducks_bigint("9223372036854775807")
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
#' @examples
#' rducks_ubigint(0:2)
#' rducks_ubigint("18446744073709551615")
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
#' @examples
#' rducks_uuid("550e8400-e29b-41d4-a716-446655440000")
#' @export
rducks_uuid <- function(x = character()) {
  structure(.Call(RDUCKS_uuid_normalize_strings, x), class = c("rducks_uuid", "character"))
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
#' @examples
#' rducks_hugeint(1:3)
#' rducks_hugeint("170141183460469231731687303715884105727")
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
#' @examples
#' rducks_uhugeint(0:2)
#' rducks_uhugeint("340282366920938463463374607431768211455")
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
    x <- as.numeric(x)
    out <- rep(NA_character_, length(x))
    nan <- is.nan(x)
    missing <- is.na(x) & !nan
    bad <- nan | (!missing & !is.finite(x))
    if (any(bad)) {
      stop("DECIMAL numeric values must be finite or NA", call. = FALSE)
    }
    out[!missing] <- format(x[!missing], scientific = FALSE, trim = TRUE, digits = 17L)
    x <- out
  } else {
    x <- as.character(x)
  }
  .Call(RDUCKS_normalize_decimal_string, x, as.integer(width), as.integer(scale))
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
#' @examples
#' rducks_decimal(c(1.5, 2.25, NA), width = 10, scale = 2)
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

rducks_interval_i32_component <- function(x, what) {
  if (!(is.integer(x) || is.numeric(x)) && !(is.logical(x) && all(is.na(x)))) {
    stop(what, " must fit in signed 32-bit integers", call. = FALSE)
  }
  x <- as.numeric(x)
  nan <- is.nan(x)
  missing <- is.na(x) & !nan
  bad <- nan | (!missing & (!is.finite(x) | x != trunc(x) | x < -2147483648 | x > 2147483647))
  if (any(bad)) {
    stop(what, " must fit in signed 32-bit integers", call. = FALSE)
  }
  as.integer(x)
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
#' @examples
#' rducks_interval(months = 1L, days = 15L, micros = 0L)
#' rducks_interval(days = c(1L, 2L, NA_integer_))
#' @export
rducks_interval <- function(months = 0L, days = 0L, micros = 0L) {
  n <- max(length(months), length(days), length(micros))
  months <- rep(months, length.out = n)
  days <- rep(days, length.out = n)
  micros <- rep(micros, length.out = n)
  months <- rducks_interval_i32_component(months, "months")
  days <- rducks_interval_i32_component(days, "days")
  micros <- rducks_normalize_integer_string(micros, unsigned = FALSE, what = "INTERVAL micros")
  micros <- rducks_check_integer_bounds(micros, "-9223372036854775808", "9223372036854775807", "INTERVAL micros")
  structure(
    list(
      months = months,
      days = days,
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
    months = as.numeric(months) + as.numeric(rhs_months),
    days = as.numeric(days) + as.numeric(rhs_days),
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
  .Call(RDUCKS_pack_bits, bits)
}

rducks_unpack_bits <- function(data, bit_length) {
  .Call(RDUCKS_unpack_bits, data, as.integer(bit_length))
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
#' @examples
#' b <- rducks_bits("10110")
#' as.character(b)
#' rducks_bits_raw(b)
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
    return(structure(.Call(RDUCKS_bits_from_character, x), class = "rducks_bits"))
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
as.character.rducks_bits <- function(x, ...) .Call(RDUCKS_bits_to_character, x$data, as.integer(x$length))[[1L]]

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
#' @examples
#' rducks_enum(c("a", "b", NA), levels = c("a", "b", "c"))
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
#' @examples
#' rducks_union("num", 42L)
#' rducks_union("str", "hello")
#' @export
rducks_union <- function(tag, value) {
  rducks_assert_non_empty_character_scalar(tag, "tag")
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
#' classes used to represent DuckDB-specific values.
#'
#' @param x A value object.
#' @param ... Reserved for methods.
#' @return `rducks_value_type()` returns a DuckDB type string.
#' @examples
#' rducks_value_type(rducks_bigint(1L))
#' rducks_value_type(rducks_decimal(1.5, width = 10, scale = 2))
#' rducks_duckdb_literal(rducks_bigint("42"))
#' rducks_duckdb_literal(rducks_uuid("550e8400-e29b-41d4-a716-446655440000"))
#' @export
rducks_value_type <- S7::new_generic(
  "rducks_value_type",
  "x",
  function(x, ...) S7::S7_dispatch()
)

#' @rdname rducks_value_type
#' @export
rducks_duckdb_literal <- S7::new_generic(
  "rducks_duckdb_literal",
  "x",
  function(x, ...) S7::S7_dispatch()
)

rducks_bigint_value_class <- S7::new_S3_class("rducks_bigint")
rducks_ubigint_value_class <- S7::new_S3_class("rducks_ubigint")
rducks_uuid_value_class <- S7::new_S3_class("rducks_uuid")
rducks_hugeint_value_class <- S7::new_S3_class("rducks_hugeint")
rducks_uhugeint_value_class <- S7::new_S3_class("rducks_uhugeint")
rducks_decimal_value_class <- S7::new_S3_class("rducks_decimal")
rducks_interval_value_class <- S7::new_S3_class("rducks_interval")
rducks_bits_value_class <- S7::new_S3_class("rducks_bits")
rducks_enum_value_class <- S7::new_S3_class("rducks_enum")
rducks_union_value_class <- S7::new_S3_class("rducks_union")

S7::method(rducks_value_type, S7::class_any) <- function(x) {
  stop("no Rducks DuckDB type mapping for objects of class: ", paste(class(x), collapse = ", "), call. = FALSE)
}

S7::method(rducks_duckdb_literal, S7::class_any) <- function(x) {
  stop("no DuckDB literal method for objects of class: ", paste(class(x), collapse = ", "), call. = FALSE)
}

rducks_sql_quote <- function(x) paste0("'", gsub("'", "''", x, fixed = TRUE), "'")

rducks_scalar_literal_check <- function(x) {
  if (length(x) != 1L) stop("DuckDB literal conversion requires a scalar value", call. = FALSE)
  invisible(NULL)
}

S7::method(rducks_value_type, rducks_bigint_value_class) <- function(x) "BIGINT"

S7::method(rducks_duckdb_literal, rducks_bigint_value_class) <- function(x) {
  rducks_scalar_literal_check(x)
  if (is.na(x)) return("NULL::BIGINT")
  paste0(rducks_sql_quote(unclass(x)), "::BIGINT")
}

S7::method(rducks_value_type, rducks_ubigint_value_class) <- function(x) "UBIGINT"

S7::method(rducks_duckdb_literal, rducks_ubigint_value_class) <- function(x) {
  rducks_scalar_literal_check(x)
  if (is.na(x)) return("NULL::UBIGINT")
  paste0(rducks_sql_quote(unclass(x)), "::UBIGINT")
}

S7::method(rducks_value_type, rducks_uuid_value_class) <- function(x) "UUID"

S7::method(rducks_duckdb_literal, rducks_uuid_value_class) <- function(x) {
  rducks_scalar_literal_check(x)
  if (is.na(x)) return("NULL::UUID")
  paste0(rducks_sql_quote(unclass(x)), "::UUID")
}

S7::method(rducks_value_type, rducks_hugeint_value_class) <- function(x) "HUGEINT"

S7::method(rducks_duckdb_literal, rducks_hugeint_value_class) <- function(x) {
  rducks_scalar_literal_check(x)
  if (is.na(x)) return("NULL::HUGEINT")
  paste0(rducks_sql_quote(unclass(x)), "::HUGEINT")
}

S7::method(rducks_value_type, rducks_uhugeint_value_class) <- function(x) "UHUGEINT"

S7::method(rducks_duckdb_literal, rducks_uhugeint_value_class) <- function(x) {
  rducks_scalar_literal_check(x)
  if (is.na(x)) return("NULL::UHUGEINT")
  paste0(rducks_sql_quote(unclass(x)), "::UHUGEINT")
}

S7::method(rducks_value_type, rducks_decimal_value_class) <- function(x) {
  sprintf("DECIMAL(%d, %d)", x$width, x$scale)
}

S7::method(rducks_duckdb_literal, rducks_decimal_value_class) <- function(x) {
  rducks_scalar_literal_check(x)
  if (is.na(x$value)) return(paste0("NULL::", rducks_value_type(x)))
  paste0(rducks_sql_quote(x$value), "::", rducks_value_type(x))
}

S7::method(rducks_value_type, rducks_interval_value_class) <- function(x) "INTERVAL"

S7::method(rducks_duckdb_literal, rducks_interval_value_class) <- function(x) {
  rducks_scalar_literal_check(x)
  if (is.na(x$months) || is.na(x$days) || is.na(x$micros)) return("NULL::INTERVAL")
  sprintf(
    "((INTERVAL '1 month' * %d) + (INTERVAL '1 day' * %d) + (INTERVAL '1 microsecond' * %s))",
    x$months, x$days, x$micros
  )
}

S7::method(rducks_value_type, rducks_bits_value_class) <- function(x) "BIT"

S7::method(rducks_duckdb_literal, rducks_bits_value_class) <- function(x) {
  paste0(rducks_sql_quote(as.character(x)), "::BIT")
}

S7::method(rducks_value_type, rducks_enum_value_class) <- function(x) {
  paste0("ENUM(", paste(vapply(levels(x), rducks_sql_quote, character(1)), collapse = ", "), ")")
}

S7::method(rducks_duckdb_literal, rducks_enum_value_class) <- function(x) {
  rducks_scalar_literal_check(x)
  if (is.na(x)) return(paste0("NULL::", rducks_value_type(x)))
  paste0(rducks_sql_quote(as.character(x)), "::", rducks_value_type(x))
}

S7::method(rducks_value_type, rducks_union_value_class) <- function(x) paste0("UNION member ", x$tag)

S7::method(rducks_duckdb_literal, rducks_union_value_class) <- function(x) {
  stop("DuckDB UNION literals require a declared union type and are not generated by rducks_duckdb_literal()", call. = FALSE)
}

#' @export
length.rducks_bits <- function(x) x$length

#' @export
`[.rducks_bits` <- function(x, i, ...) {
  bits <- rducks_unpack_bits(x$data, x$length)
  rducks_bits(bits[i])
}

rducks_compare_integer_strings <- function(a, b) {
  .Call(RDUCKS_compare_integer_strings, a, b)
}

rducks_integer_add_strings <- function(a, b) {
  .Call(RDUCKS_integer_add_strings, a, b)
}

rducks_integer_negate_strings <- function(x) {
  .Call(RDUCKS_integer_negate_strings, x)
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
  converted <- .Call(RDUCKS_integer_strings_to_double, unclass(x))
  if (isTRUE(converted$warn)) {
    warning(what, " converted through R double; precision may be lost", call. = FALSE)
  }
  converted$values
}

#' @export
as.double.rducks_bigint <- function(x, ...) rducks_integer_double(x, "BIGINT")

#' @export
as.numeric.rducks_bigint <- function(x, ...) as.double.rducks_bigint(x, ...)

#' @export
as.integer.rducks_bigint <- function(x, ...) .Call(RDUCKS_integer_strings_to_int32, unclass(x))

#' @export
as.double.rducks_ubigint <- function(x, ...) rducks_integer_double(x, "UBIGINT")

#' @export
as.numeric.rducks_ubigint <- function(x, ...) as.double.rducks_ubigint(x, ...)

#' @export
as.integer.rducks_ubigint <- function(x, ...) .Call(RDUCKS_integer_strings_to_int32, unclass(x))

#' @export
as.double.rducks_hugeint <- function(x, ...) rducks_integer_double(x, "HUGEINT")

#' @export
as.numeric.rducks_hugeint <- function(x, ...) as.double.rducks_hugeint(x, ...)

#' @export
as.integer.rducks_hugeint <- function(x, ...) .Call(RDUCKS_integer_strings_to_int32, unclass(x))

#' @export
as.double.rducks_uhugeint <- function(x, ...) rducks_integer_double(x, "UHUGEINT")

#' @export
as.numeric.rducks_uhugeint <- function(x, ...) as.double.rducks_uhugeint(x, ...)

#' @export
as.integer.rducks_uhugeint <- function(x, ...) .Call(RDUCKS_integer_strings_to_int32, unclass(x))

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
  .Call(RDUCKS_decimal_scaled_integer_strings, x$value)
}

rducks_decimal_from_scaled_integer <- function(x, width, scale) {
  spec <- rducks_check_decimal_spec(width, scale)
  value <- .Call(RDUCKS_decimal_from_scaled_integer_strings, x, spec[["width"]], spec[["scale"]])
  structure(list(value = value, width = spec[["width"]], scale = spec[["scale"]]), class = "rducks_decimal")
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
  .Call(RDUCKS_decimal_compare_values, a$value, b$value)
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
  data <- .Call(RDUCKS_bits_binary_raw, e1$data, e2$data, as.integer(e1$length), op)
  structure(list(data = data, length = e1$length), class = "rducks_bits")
}

#' BIT logical operations
#'
#' @param e1,e2 `rducks_bits` values, raw bytes, or 0/1 vectors.
#' @return `rducks_bits` for bitwise operations or logical values for equality.
#' @examples
#' a <- rducks_bits("1010")
#' b <- rducks_bits("1100")
#' as.character(a & b)
#' as.character(a | b)
#' as.character(rducks_bits_xor(a, b))
#' a == b
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
  x <- rducks_bits(x)
  data <- .Call(RDUCKS_bits_not_raw, x$data, as.integer(x$length))
  structure(list(data = data, length = x$length), class = "rducks_bits")
}
