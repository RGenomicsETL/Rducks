rducks_seconds_to_micros <- function(seconds, what = "time duration") {
  if (!is.numeric(seconds)) {
    stop(what, " must be numeric seconds", call. = FALSE)
  }
  out <- rep(NA_character_, length(seconds))
  bad <- !is.na(seconds) & !is.finite(seconds)
  if (any(bad)) {
    stop(what, " must be finite or missing", call. = FALSE)
  }
  out[!is.na(seconds)] <- format(round(seconds[!is.na(seconds)] * 1000000), scientific = FALSE, trim = TRUE)
  out
}

rducks_check_time_seconds <- function(seconds, what = "DuckDB TIME") {
  rounded_micros <- round(seconds * 1000000)
  bad <- !is.na(seconds) & (!is.finite(seconds) | seconds < 0 | seconds >= 86400 |
    rounded_micros < 0 | rounded_micros >= 86400000000)
  if (any(bad)) {
    stop(what, " values must be finite seconds in [0, 86400) after microsecond rounding", call. = FALSE)
  }
  seconds
}

rducks_check_finite_time_number <- function(x, what) {
  bad <- !is.na(x) & !is.finite(x)
  if (any(bad)) {
    stop(what, " values must be finite or missing", call. = FALSE)
  }
  x
}

rducks_parse_time_string <- function(x) {
  out <- rep(NA_real_, length(x))
  missing <- is.na(x)
  pattern <- "^\\s*([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}(?:\\.[0-9]+)?))?\\s*$"
  for (i in which(!missing)) {
    m <- regexec(pattern, x[[i]], perl = TRUE)
    parts <- regmatches(x[[i]], m)[[1L]]
    if (!length(parts)) {
      stop("character time values must use HH:MM or HH:MM:SS[.ffffff]", call. = FALSE)
    }
    hour <- as.integer(parts[[2L]])
    minute <- as.integer(parts[[3L]])
    second <- if (length(parts) >= 4L && nzchar(parts[[4L]])) as.numeric(parts[[4L]]) else 0
    if (hour > 23L || minute > 59L || second < 0 || second >= 60) {
      stop("time values must be within one day", call. = FALSE)
    }
    out[[i]] <- hour * 3600 + minute * 60 + second
  }
  rducks_check_time_seconds(out)
}

#' Convert R date/time values to Rducks scalar-UDF shapes
#'
#' These helpers normalize common R date/time inputs to the R value shapes used
#' by Rducks DuckDB scalar-UDF marshalling for `DATE`, `TIME`, `TIMESTAMP`, and
#' `INTERVAL` values.
#'
#' @param x,start,end R date/time value. Supported inputs include `Date`,
#'   `POSIXct`/`POSIXlt`, `difftime`, numeric seconds where documented, and
#'   character strings accepted by base R or `HH:MM:SS[.ffffff]` for times.
#'   Numeric `DATE`/`TIMESTAMP` inputs must be finite or missing. DuckDB `TIME`
#'   inputs must be finite seconds in `[0, 86400)` or missing.
#' @param tz Time zone used when converting date-times.
#' @param origin Origin for numeric timestamp/date input.
#' @param units Units for numeric interval input.
#' @param months,days Extra interval month/day components for
#'   `rducks_as_interval()`.
#'
#' Numeric and `difftime` intervals are rounded to the nearest microsecond before
#' constructing `rducks_interval()`.
#' @return `rducks_as_date()` returns a `Date` vector; `rducks_as_time()` returns
#'   numeric seconds since midnight; `rducks_as_timestamp()` returns `POSIXct`;
#'   `rducks_as_interval()` and `rducks_interval_between()` return
#'   `rducks_interval`.
#' @examples
#' rducks_as_date(as.Date("2024-01-15"))
#' rducks_as_date("2024-01-15")
#' rducks_as_timestamp(as.POSIXct("2024-01-15 12:00:00", tz = "UTC"))
#' rducks_as_time("08:30:00")
#' rducks_as_interval(3600, units = "secs")
#' rducks_interval_between(
#'   as.POSIXct("2024-01-01", tz = "UTC"),
#'   as.POSIXct("2024-01-02", tz = "UTC")
#' )
#' @export
rducks_as_date <- function(x, tz = "UTC", origin = "1970-01-01") {
  if (inherits(x, "Date")) {
    rducks_check_finite_time_number(unclass(x), "Date")
    return(x)
  }
  if (inherits(x, "POSIXt")) {
    rducks_check_finite_time_number(unclass(as.POSIXct(x, tz = tz)), "POSIXt")
    return(as.Date(x, tz = tz))
  }
  if (is.numeric(x)) {
    rducks_check_finite_time_number(x, "numeric date")
    return(as.Date(x, origin = origin))
  }
  as.Date(x)
}

#' @rdname rducks_as_date
#' @export
rducks_as_timestamp <- function(x, tz = "UTC", origin = "1970-01-01") {
  if (inherits(x, "POSIXct")) {
    out <- as.POSIXct(x, tz = tz)
    rducks_check_finite_time_number(unclass(out), "POSIXct")
    return(out)
  }
  if (inherits(x, "POSIXlt")) {
    out <- as.POSIXct(x, tz = tz)
    rducks_check_finite_time_number(unclass(out), "POSIXlt")
    return(out)
  }
  if (inherits(x, "Date")) {
    rducks_check_finite_time_number(unclass(x), "Date")
    return(as.POSIXct(x, tz = tz))
  }
  if (is.numeric(x)) {
    rducks_check_finite_time_number(x, "numeric timestamp")
    return(as.POSIXct(x, origin = origin, tz = tz))
  }
  as.POSIXct(x, tz = tz)
}

#' @rdname rducks_as_date
#' @export
rducks_as_time <- function(x, tz = "UTC") {
  if (inherits(x, "POSIXt")) {
    rducks_check_finite_time_number(unclass(as.POSIXct(x, tz = tz)), "POSIXt")
    lt <- as.POSIXlt(x, tz = tz)
    return(rducks_check_time_seconds(lt$hour * 3600 + lt$min * 60 + lt$sec))
  }
  if (inherits(x, "difftime")) {
    seconds <- as.numeric(x, units = "secs")
    return(rducks_check_time_seconds(seconds))
  }
  if (is.character(x)) {
    return(rducks_parse_time_string(x))
  }
  if (is.numeric(x)) {
    return(rducks_check_time_seconds(as.numeric(x)))
  }
  stop("x must be POSIXt, difftime, character, or numeric for DuckDB TIME", call. = FALSE)
}

#' @rdname rducks_as_date
#' @export
rducks_as_interval <- function(x, units = c("secs", "mins", "hours", "days", "weeks"), months = 0L, days = 0L) {
  units <- match.arg(units)
  if (inherits(x, "rducks_interval")) {
    return(rducks_interval(months = x$months + months, days = x$days + days, micros = x$micros))
  }
  seconds <- if (inherits(x, "difftime")) {
    as.numeric(x, units = "secs")
  } else if (is.numeric(x)) {
    multiplier <- switch(units, secs = 1, mins = 60, hours = 3600, days = 86400, weeks = 604800)
    as.numeric(x) * multiplier
  } else {
    stop("x must be difftime, numeric, or rducks_interval", call. = FALSE)
  }
  rducks_interval(months = months, days = days, micros = rducks_seconds_to_micros(seconds, "interval"))
}

#' @rdname rducks_as_date
#' @export
rducks_interval_between <- function(start, end, tz = "UTC") {
  start <- rducks_as_timestamp(start, tz = tz)
  end <- rducks_as_timestamp(end, tz = tz)
  rducks_as_interval(difftime(end, start, units = "secs"))
}
