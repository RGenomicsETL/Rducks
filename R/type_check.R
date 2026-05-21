rducks_check_length <- function(x, size, what) {
  if (!is.null(size) && length(x) != size) {
    stop(what, " must have length ", size, call. = FALSE)
  }
  invisible(TRUE)
}

rducks_check_scalar_value <- function(token, x, size = NULL, what = "value") {
  rducks_check_length(x, size, what)
  ok <- switch(token,
    bool = is.logical(x),
    i8 = is.integer(x) || is.numeric(x),
    u8 = is.integer(x) || is.numeric(x),
    i16 = is.integer(x) || is.numeric(x),
    u16 = is.integer(x) || is.numeric(x),
    i32 = is.integer(x) || is.numeric(x),
    u32 = is.integer(x) || is.numeric(x),
    i64 = inherits(x, "rducks_bigint"),
    u64 = inherits(x, "rducks_ubigint"),
    f32 = is.numeric(x),
    f64 = is.numeric(x),
    varchar = is.character(x),
    blob = is.raw(x),
    geometry = is.raw(x),
    variant = is.list(x),
    date = inherits(x, "Date") || is.numeric(x),
    time = is.numeric(x),
    timestamp = inherits(x, "POSIXct") || is.numeric(x),
    hugeint = inherits(x, "rducks_hugeint"),
    uhugeint = inherits(x, "rducks_uhugeint"),
    uuid = inherits(x, "rducks_uuid"),
    interval = inherits(x, "rducks_interval"),
    bit = inherits(x, "rducks_bits") || (is.list(x) && all(vapply(x, inherits, logical(1), what = "rducks_bits"))),
    FALSE
  )
  if (!isTRUE(ok)) {
    stop(what, " is not compatible with ", rducks_duckdb_type_one(token), call. = FALSE)
  }
  if (identical(token, "variant")) {
    rducks_check_value(rducks_variant_storage_type(), x, what = what)
    return(invisible(TRUE))
  }
  integer_ranges <- list(
    i8 = c(-128, 127), u8 = c(0, 255),
    i16 = c(-32768, 32767), u16 = c(0, 65535),
    i32 = c(-2147483648, 2147483647), u32 = c(0, 4294967295)
  )
  if (token %in% names(integer_ranges)) {
    v <- as.numeric(x)
    range <- integer_ranges[[token]]
    bad <- is.nan(v) | (!is.na(v) & (!is.finite(v) | v != trunc(v) | v < range[[1L]] | v > range[[2L]]))
    if (any(bad)) {
      stop(what, " must contain finite whole-number values in range for ", rducks_duckdb_type_one(token), call. = FALSE)
    }
  }
  if (identical(token, "date")) {
    v <- as.numeric(x)
    bad <- is.nan(v) | (!is.na(v) & (!is.finite(v) | v != trunc(v) | v < -2147483648 | v > 2147483647))
    if (any(bad)) {
      stop(what, " must contain finite whole-day values in range for DATE", call. = FALSE)
    }
  }
  if (identical(token, "time")) {
    v <- as.numeric(x)
    rounded_micros <- round(v * 1000000)
    bad <- is.nan(v) | (!is.na(v) & (!is.finite(v) | v < 0 | v >= 86400 |
      rounded_micros < 0 | rounded_micros >= 86400000000))
    if (any(bad)) {
      stop(what, " must contain finite seconds in [0, 86400) for TIME", call. = FALSE)
    }
  }
  if (identical(token, "timestamp")) {
    v <- as.numeric(x)
    bad <- is.nan(v) | (!is.na(v) & (!is.finite(v) | v < -9223372036854.774 | v > 9223372036854.774))
    if (any(bad)) {
      stop(what, " must contain finite POSIXct-compatible seconds for TIMESTAMP", call. = FALSE)
    }
  }
  invisible(TRUE)
}

rducks_check_sequence_value <- function(type, x, size = NULL, what = "value") {
  child <- rducks_type_children(type)[[1L]]
  child_kind <- rducks_type_kind(child)
  rducks_check_length(x, size, what)
  if (identical(child_kind, "scalar") && !rducks_type_token(child) %in% c("blob", "geometry", "variant")) {
    rducks_check_value(child, x, what = what)
    return(invisible(TRUE))
  }
  if (child_kind %in% c("decimal", "enum")) {
    if (is.list(x) && !inherits(x, c("rducks_decimal", "rducks_enum"))) {
      for (i in seq_along(x)) {
        rducks_check_value(child, x[[i]], what = sprintf("%s[[%d]]", what, i))
      }
    } else {
      rducks_check_value(child, x, what = what)
    }
    return(invisible(TRUE))
  }
  if (!is.list(x)) {
    stop(what, " must be a list for ", rducks_type_duckdb_sql(type), call. = FALSE)
  }
  for (i in seq_along(x)) {
    rducks_check_value(child, x[[i]], what = sprintf("%s[[%d]]", what, i))
  }
  invisible(TRUE)
}

rducks_check_struct_value <- function(type, x, what) {
  if (!is.list(x)) {
    stop(what, " must be a list for ", rducks_type_duckdb_sql(type), call. = FALSE)
  }
  children <- rducks_type_children(type)
  field_names <- rducks_type_child_names(type)
  value_names <- names(x)
  for (i in seq_along(children)) {
    name <- field_names[[i]]
    if (!is.null(value_names) && any(nzchar(value_names))) {
      if (!name %in% value_names) {
        stop(what, " is missing STRUCT field ", name, call. = FALSE)
      }
      field_value <- x[[name]]
    } else if (i <= length(x)) {
      field_value <- x[[i]]
    } else {
      stop(what, " is missing STRUCT field ", name, call. = FALSE)
    }
    rducks_check_value(children[[i]], field_value, what = paste0(what, "$", name))
  }
  invisible(TRUE)
}

rducks_check_map_value <- function(type, x, what) {
  if (!is.list(x) || is.null(x$keys) || is.null(x$values)) {
    stop(what, " must be list(keys = ..., values = ...) for ", rducks_type_duckdb_sql(type), call. = FALSE)
  }
  children <- rducks_type_children(type)
  if (length(x$keys) != length(x$values)) {
    stop(what, "$keys and ", what, "$values must have equal length", call. = FALSE)
  }
  rducks_check_sequence_value(LIST(children[[1L]]), x$keys, what = paste0(what, "$keys"))
  rducks_check_sequence_value(LIST(children[[2L]]), x$values, what = paste0(what, "$values"))
  invisible(TRUE)
}

rducks_check_decimal_value <- function(type, x, what) {
  params <- rducks_type_parameters(type)
  if (!inherits(x, "rducks_decimal")) {
    stop(what, " must be a rducks_decimal object for ", rducks_type_duckdb_sql(type), call. = FALSE)
  }
  if (!identical(as.integer(x$width), as.integer(params$width)) || !identical(as.integer(x$scale), as.integer(params$scale))) {
    stop(what, " must have type ", rducks_type_duckdb_sql(type), call. = FALSE)
  }
  invisible(TRUE)
}

rducks_check_enum_value <- function(type, x, what) {
  levels <- rducks_type_parameters(type)$levels
  if (inherits(x, "rducks_enum")) {
    if (!identical(base::levels(x), levels)) {
      stop(what, " enum levels must match ", rducks_type_duckdb_sql(type), call. = FALSE)
    }
    return(invisible(TRUE))
  }
  values <- as.character(x)
  bad <- !is.na(values) & !values %in% levels
  if (any(bad)) {
    stop(what, " enum values must be present in ", rducks_type_duckdb_sql(type), call. = FALSE)
  }
  invisible(TRUE)
}

rducks_check_union_value <- function(type, x, what) {
  tag <- x$tag
  value <- x$value
  if (!rducks_is_non_empty_character_scalar(tag)) {
    stop(what, " must have a non-empty union tag", call. = FALSE)
  }
  member_names <- rducks_type_child_names(type)
  idx <- match(tag, member_names)
  if (is.na(idx)) {
    stop(what, " union tag must be one of: ", paste(member_names, collapse = ", "), call. = FALSE)
  }
  rducks_check_value(rducks_type_children(type)[[idx]], value, what = paste0(what, "$", tag))
  invisible(TRUE)
}

#' Check that an R value is compatible with a DuckDB type
#'
#' This is a pre-marshalling guard for Rducks type descriptors. It checks the R
#' value shape that the marshaller expects for scalar, decimal, enum, list,
#' array, struct, map, and union descriptors.
#'
#' @param type A `rducks_type` descriptor such as `INTEGER`, `INTEGER[]`,
#'   `STRUCT(a = INTEGER)`, or a character scalar token accepted by
#'   \code{\link[=rducks_type_normalize]{rducks_type_normalize()}}.
#' @param x R value to check.
#' @param size Optional exact length for scalar/vector checks.
#' @param what Label used in error messages.
#' @param name Argument label used by `rducks_check_argument()` in error
#'   messages.
#' @return `x`, invisibly, on success.
#' @examples
#' rducks_check_value(INTEGER, 42L)
#' rducks_check_value(VARCHAR, "hello")
#' rducks_check_argument(DOUBLE, 3.14, name = "x")
#' rducks_check_return(BOOLEAN, TRUE)
#' @export
rducks_check_value <- function(type, x, size = NULL, what = "value") {
  if (!rducks_type_inherits(type, "rducks_type")) {
    type <- rducks_type_object(type)
  }
  if (is.null(x)) {
    return(invisible(x))
  }
  kind <- rducks_type_kind(type)
  if (identical(kind, "scalar")) {
    rducks_check_scalar_value(rducks_type_token(type), x, size = size, what = what)
  } else if (identical(kind, "decimal")) {
    rducks_check_decimal_value(type, x, what)
  } else if (identical(kind, "enum")) {
    rducks_check_enum_value(type, x, what)
  } else if (identical(kind, "list")) {
    rducks_check_sequence_value(type, x, size = size, what = what)
  } else if (identical(kind, "array")) {
    rducks_check_sequence_value(type, x, size = rducks_type_size(type), what = what)
  } else if (identical(kind, "struct")) {
    rducks_check_struct_value(type, x, what)
  } else if (identical(kind, "map")) {
    rducks_check_map_value(type, x, what)
  } else if (identical(kind, "union")) {
    rducks_check_union_value(type, x, what)
  } else {
    stop("unsupported type kind: ", kind, call. = FALSE)
  }
  invisible(x)
}

#' @rdname rducks_check_value
#' @export
rducks_check_argument <- function(type, x, name = "argument") {
  rducks_check_value(type, x, what = name)
}

#' @rdname rducks_check_value
#' @export
rducks_check_return <- function(type, x) {
  rducks_check_value(type, x, what = "return value")
}
