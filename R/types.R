rducks_scalar_type_table <- data.frame(
  type_token = c(
    "bool", "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64",
    "f32", "f64", "varchar", "blob", "geometry", "variant", "date", "time", "timestamp",
    "hugeint", "uhugeint", "uuid", "interval", "bit"
  ),
  duckdb_type = c(
    "BOOLEAN", "TINYINT", "UTINYINT", "SMALLINT", "USMALLINT", "INTEGER", "UINTEGER",
    "BIGINT", "UBIGINT", "FLOAT", "DOUBLE", "VARCHAR", "BLOB", "GEOMETRY", "VARIANT", "DATE", "TIME", "TIMESTAMP",
    "HUGEINT", "UHUGEINT", "UUID", "INTERVAL", "BIT"
  ),
  descriptor_kind = rep("scalar", 23L),
  r_value_class = c(
    "logical", "integer", "integer", "integer", "integer", "integer", "numeric",
    "rducks_bigint", "rducks_ubigint", "numeric", "numeric", "character", "raw",
    "raw", "rducks_variant", "Date", "numeric", "POSIXct", "rducks_hugeint", "rducks_uhugeint",
    "rducks_uuid", "rducks_interval", "rducks_bits"
  ),
  r_argument_shape = c(
    "logical scalar", "integer scalar", "integer scalar", "integer scalar", "integer scalar", "integer scalar",
    "numeric scalar", "rducks_bigint scalar", "rducks_ubigint scalar", "numeric scalar",
    "numeric scalar", "character scalar", "raw vector", "raw WKB geometry vector",
    "rducks_variant storage object", "Date scalar", "numeric seconds scalar",
    "POSIXct scalar", "rducks_hugeint scalar", "rducks_uhugeint scalar", "rducks_uuid scalar",
    "rducks_interval scalar", "rducks_bits scalar"
  ),
  special_null_argument = c(
    "NA", "NA_integer_", "NA_integer_", "NA_integer_", "NA_integer_", "NA_integer_",
    "NA_real_", "NULL", "NULL", "NA_real_", "NA_real_", "NA_character_",
    "NULL", "NULL", "NULL", "Date NA", "NA_real_", "POSIXct NA",
    "NULL", "NULL", "NULL", "NULL", "NULL"
  ),
  copy_semantics = c(
    rep("boxed scalar", 7L), rep("boxed exact Rducks value", 2L), rep("boxed scalar", 2L),
    "string copied into R", "bytes copied into R", "WKB bytes copied into R",
    "recursive R allocation for DuckDB VARIANT storage", rep("boxed scalar", 3L),
    rep("boxed exact Rducks value", 5L)
  ),
  integer_uses_r_double = c(rep(FALSE, 6L), TRUE, rep(FALSE, 16L)),
  float32_widens_to_r_double = c(rep(FALSE, 9L), TRUE, rep(FALSE, 13L)),
  precision_may_be_lost = FALSE,
  notes = c(
    "", "", "", "", "", "", "uses R numeric because UINTEGER exceeds R integer range", "exact signed 64-bit integer value",
    "exact unsigned 64-bit integer value", "DuckDB FLOAT is widened to R numeric", "", "string copied into R",
    "bytes copied into R", "GEOMETRY crosses the R boundary as WKB raw bytes", "VARIANT crosses the R boundary as DuckDB's typed storage object",
    "days since 1970-01-01", "microseconds converted to seconds",
    "microseconds converted to seconds", rep("exact Rducks value class", 5L)
  ),
  stringsAsFactors = FALSE,
  check.names = FALSE
)

rducks_scalar_type_row <- function(token) {
  token <- rducks_type_normalize_scalar(token)
  row <- rducks_scalar_type_table[rducks_scalar_type_table$type_token == token, , drop = FALSE]
  row.names(row) <- NULL
  row
}

rducks_all_scalar_type_names <- function() {
  rducks_scalar_type_table$type_token
}

rducks_type_normalize_scalar <- function(token, original = token) {
  token <- tolower(trimws(token))
  if (!token %in% rducks_all_scalar_type_names()) {
    stop("unsupported scalar Rducks type token: ", original, call. = FALSE)
  }
  token
}

rducks_scalar_duckdb_sql <- function(token) {
  rducks_scalar_type_row(token)$duckdb_type[[1L]]
}

rducks_reject_character_composite_type <- function(token) {
  stop(
    "composite, DECIMAL, ENUM, and UNION types must be constructed with ",
    "Rducks type constructors such as LIST(), ARRAY(), STRUCT(), MAP(), ",
    "DECIMAL(), ENUM(), and UNION(); quoted composite type strings are not supported",
    call. = FALSE
  )
}

#' Normalize an Rducks type token
#'
#' Character input is limited to canonical scalar tokens such as `i32`, `f64`,
#' and `varchar`. Composite, DECIMAL, ENUM, and UNION types are represented by
#' constructed `rducks_type` descriptors rather than quoted type strings.
#'
#' @param x Character scalar type token or a `rducks_type` descriptor.
#' @return Canonical scalar token for character input, or the descriptor's wire
#'   token for a `rducks_type`.
#' @examples
#' rducks_type_normalize("i32")
#' rducks_type_normalize(INTEGER)
#' rducks_type_normalize(LIST(VARCHAR))
#' @export
rducks_type_normalize <- function(x) {
  if (rducks_type_inherits(x, "rducks_type")) {
    return(rducks_type_token(x))
  }
  if (!rducks_is_non_empty_character_scalar(x)) {
    stop("type must be a non-empty scalar token or rducks_type descriptor", call. = FALSE)
  }
  chars <- strsplit(x, "", fixed = TRUE)[[1L]]
  if (any(chars %in% c("<", ">", "[", "]", "(", ")", ":", ";", ","))) {
    rducks_reject_character_composite_type(x)
  }
  rducks_type_normalize_scalar(x, x)
}

rducks_as_type <- function(x) {
  if (rducks_type_inherits(x, "rducks_type")) {
    return(x)
  }
  rducks_type_object(x)
}

rducks_as_type_list <- function(x) {
  if (is.null(x)) {
    return(list())
  }
  if (rducks_type_inherits(x, "rducks_type")) {
    return(list(x))
  }
  if (rducks_type_inherits(x, "rducks_type_list") || is.list(x)) {
    if (!all(vapply(x, rducks_type_descriptor_inherits, logical(1), class = rducks_type_class))) {
      stop("type lists must contain only rducks_type descriptors", call. = FALSE)
    }
    return(unclass(x))
  }
  if (is.character(x)) {
    return(lapply(x, rducks_type_object))
  }
  stop("types must be scalar tokens, a rducks_type descriptor, or a list of rducks_type descriptors", call. = FALSE)
}

rducks_type_scalar_leaves <- function(type) {
  if (!rducks_type_inherits(type, "rducks_type")) {
    type <- rducks_type_object(type)
  }
  if (identical(rducks_type_kind(type), "scalar")) {
    return(rducks_type_token(type))
  }
  unlist(lapply(rducks_type_children(type), rducks_type_scalar_leaves), use.names = FALSE)
}

rducks_duckdb_type_one <- function(type) {
  if (rducks_type_inherits(type, "rducks_type")) {
    return(rducks_type_duckdb_sql(type))
  }
  rducks_scalar_duckdb_sql(type)
}

rducks_type_kind_from_token <- function(token) {
  rducks_type_normalize_scalar(token)
  "scalar"
}

rducks_type_object <- function(token) {
  token <- rducks_type_normalize_scalar(token)
  rducks_type_construct_s7(
    token = token,
    duckdb_sql = rducks_scalar_duckdb_sql(token),
    kind = "scalar",
    children = list(),
    child_names = character(),
    size = NA_integer_,
    parameters = list()
  )
}

rducks_token_chars <- function(x) strsplit(x, "", fixed = TRUE)[[1L]]

rducks_find_top_level_char <- function(x, target) {
  chars <- rducks_token_chars(x)
  angle <- 0L
  square <- 0L
  for (i in seq_along(chars)) {
    ch <- chars[[i]]
    if (identical(ch, "<")) angle <- angle + 1L
    else if (identical(ch, ">")) angle <- max(0L, angle - 1L)
    else if (identical(ch, "[")) square <- square + 1L
    else if (identical(ch, "]")) square <- max(0L, square - 1L)
    else if (identical(ch, target) && angle == 0L && square == 0L) return(i)
  }
  NA_integer_
}

rducks_split_top_level <- function(x, sep) {
  out <- character()
  start <- 1L
  repeat {
    pos <- rducks_find_top_level_char(substr(x, start, nchar(x)), sep)
    if (is.na(pos)) {
      out <- c(out, substr(x, start, nchar(x)))
      break
    }
    end <- start + pos - 2L
    out <- c(out, substr(x, start, end))
    start <- start + pos
  }
  trimws(out)
}

rducks_token_inner <- function(token, prefix) {
  prefix <- paste0(prefix, "<")
  if (!startsWith(token, prefix) || !endsWith(token, ">")) return(NULL)
  substr(token, nchar(prefix) + 1L, nchar(token) - 1L)
}

rducks_token_percent_decode <- function(x) {
  bytes <- charToRaw(enc2utf8(x))
  out <- raw()
  i <- 1L
  while (i <= length(bytes)) {
    if (identical(bytes[[i]], charToRaw("%")[[1L]])) {
      if (i + 2L > length(bytes)) stop("invalid percent-encoded Rducks type token", call. = FALSE)
      hex <- rawToChar(bytes[i + 1:2])
      value <- suppressWarnings(strtoi(hex, base = 16L))
      if (is.na(value)) stop("invalid percent-encoded Rducks type token", call. = FALSE)
      out <- c(out, as.raw(value))
      i <- i + 3L
    } else {
      out <- c(out, bytes[[i]])
      i <- i + 1L
    }
  }
  value <- rawToChar(out)
  Encoding(value) <- "UTF-8"
  value
}

rducks_token_percent_encode <- function(x) {
  bytes <- charToRaw(enc2utf8(x))
  safe <- as.raw(c(
    charToRaw("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-.")
  ))
  paste(vapply(bytes, function(byte) {
    if (byte %in% safe) rawToChar(byte) else sprintf("%%%02X", as.integer(byte))
  }, character(1)), collapse = "")
}

rducks_token_array_suffix <- function(token) {
  chars <- rducks_token_chars(token)
  if (!length(chars) || !identical(chars[[length(chars)]], "]")) return(NULL)
  angle <- 0L
  for (i in rev(seq_along(chars))) {
    ch <- chars[[i]]
    if (identical(ch, ">")) angle <- angle + 1L
    else if (identical(ch, "<")) angle <- max(0L, angle - 1L)
    else if (identical(ch, "[") && angle == 0L) {
      return(list(prefix = substr(token, 1L, i - 1L), size = substr(token, i + 1L, nchar(token) - 1L)))
    }
  }
  NULL
}

rducks_type_from_wire_token <- function(token) {
  token <- trimws(token)
  array <- rducks_token_array_suffix(token)
  if (!is.null(array)) {
    size <- suppressWarnings(as.integer(array$size))
    if (is.na(size) || size <= 0L) stop("invalid Rducks array token: ", token, call. = FALSE)
    return(ARRAY(rducks_type_from_wire_token(array$prefix), size))
  }
  inner <- rducks_token_inner(token, "decimal")
  if (!is.null(inner)) {
    parts <- rducks_split_top_level(inner, ";")
    if (length(parts) != 2L) parts <- rducks_split_top_level(inner, ",")
    if (length(parts) != 2L) stop("invalid Rducks decimal token: ", token, call. = FALSE)
    return(DECIMAL(as.integer(parts[[1L]]), as.integer(parts[[2L]])))
  }
  inner <- rducks_token_inner(token, "enum")
  if (!is.null(inner)) {
    levels <- strsplit(inner, "|", fixed = TRUE)[[1L]]
    return(ENUM(vapply(levels, rducks_token_percent_decode, character(1))))
  }
  inner <- rducks_token_inner(token, "list")
  if (!is.null(inner)) return(LIST(rducks_type_from_wire_token(inner)))
  inner <- rducks_token_inner(token, "map")
  if (!is.null(inner)) {
    parts <- rducks_split_top_level(inner, ";")
    if (length(parts) != 2L) parts <- rducks_split_top_level(inner, ",")
    if (length(parts) != 2L) stop("invalid Rducks map token: ", token, call. = FALSE)
    return(MAP(rducks_type_from_wire_token(parts[[1L]]), rducks_type_from_wire_token(parts[[2L]])))
  }
  inner <- rducks_token_inner(token, "struct")
  if (!is.null(inner)) {
    fields <- rducks_split_top_level(inner, ";")
    values <- lapply(fields, function(field) {
      pos <- rducks_find_top_level_char(field, ":")
      if (is.na(pos)) stop("invalid Rducks struct token: ", token, call. = FALSE)
      rducks_type_from_wire_token(substr(field, pos + 1L, nchar(field)))
    })
    names(values) <- vapply(fields, function(field) {
      pos <- rducks_find_top_level_char(field, ":")
      rducks_token_percent_decode(trimws(substr(field, 1L, pos - 1L)))
    }, character(1))
    return(do.call(STRUCT, values))
  }
  inner <- rducks_token_inner(token, "union")
  if (!is.null(inner)) {
    fields <- rducks_split_top_level(inner, ";")
    values <- lapply(fields, function(field) {
      pos <- rducks_find_top_level_char(field, ":")
      if (is.na(pos)) stop("invalid Rducks union token: ", token, call. = FALSE)
      rducks_type_from_wire_token(substr(field, pos + 1L, nchar(field)))
    })
    names(values) <- vapply(fields, function(field) {
      pos <- rducks_find_top_level_char(field, ":")
      rducks_token_percent_decode(trimws(substr(field, 1L, pos - 1L)))
    }, character(1))
    return(do.call(UNION, values))
  }
  rducks_type_object(token)
}

rducks_dynamic_arg_types <- function(tokens) {
  if (is.null(tokens)) return(NULL)
  if (!is.character(tokens) || anyNA(tokens)) stop("dynamic Rducks argument type tokens must be character", call. = FALSE)
  lapply(tokens, rducks_type_from_wire_token)
}

rducks_resolve_dynamic_arg_types <- function(arg_types, dynamic_arg_tokens = NULL) {
  if (!is.null(arg_types)) return(arg_types)
  rducks_dynamic_arg_types(dynamic_arg_tokens)
}

rducks_type_name_ok <- function(x, what = "name") {
  if (!is.character(x) || !length(x) || anyNA(x) || any(!nzchar(x))) {
    stop(what, " must contain non-empty character values", call. = FALSE)
  }
  if (anyDuplicated(x)) {
    stop(what, " values must be unique", call. = FALSE)
  }
  x
}

rducks_enum_level_token <- function(levels) {
  paste(vapply(levels, rducks_token_percent_encode, character(1)), collapse = "|")
}

#' Rducks DuckDB type descriptors and constructors
#'
#' Use these descriptors and constructors in \code{\link[=rducks_register_scalar_udf]{rducks_register_scalar_udf()}}
#' and \code{\link[=rducks_register_aggregate]{rducks_register_aggregate()}} to avoid quoted type
#' specifications. Examples include `args = INTEGER`, `args = c(INTEGER,
#' DOUBLE)`, `args = INTEGER[]`, `args = INTEGER[3]`,
#' `args = STRUCT(a = INTEGER, b = VARCHAR)`, and
#' `args = MAP(VARCHAR, INTEGER)`.
#'
#' @param type Child type for `LIST()` or `ARRAY()`.
#' @param size Fixed array size for `ARRAY()`.
#' @param key,value Key and value types for `MAP()`.
#' @param width,scale DuckDB decimal width and scale for `DECIMAL()`.
#' @param levels Character vector of enum dictionary values for `ENUM()`.
#' @param ... Named field types for `STRUCT()`/`UNION()` or descriptors for `c()`.
#' @param x Object to test with `rducks_is_type()`.
#' @return A formal S7 `rducks_type` descriptor, or a `rducks_type_list` from `c()`.
#' @examples
#' INTEGER
#' rducks_is_type(INTEGER)
#' rducks_is_type("not a type")
#' LIST(VARCHAR)
#' ARRAY(INTEGER, 3L)
#' STRUCT(a = INTEGER, b = VARCHAR)
#' MAP(VARCHAR, DOUBLE)
#' DECIMAL(10L, 2L)
#' ENUM(c("small", "medium", "large"))
#' UNION(i = INTEGER, s = VARCHAR)
#' c(INTEGER, DOUBLE, VARCHAR)
#' @name rducks_type_objects
NULL

#' @rdname rducks_type_objects
#' @export
rducks_is_type <- function(x) {
  ok_scalar <- rducks_is_non_empty_character_scalar
  ok_names <- function(value) is.character(value) && length(value) > 0L && !anyNA(value) && all(nzchar(value)) && !anyDuplicated(value)
  rec <- function(x, depth = 0L) {
    if (depth > 64L || !rducks_type_inherits(x, "rducks_type") || !inherits(x, "S7_object") || !is.list(x)) {
      return(FALSE)
    }
    if (is.null(attr(x, "S7_class", exact = TRUE))) {
      return(FALSE)
    }
    required <- c("token", "duckdb_sql", "kind", "children", "child_names", "size", "parameters")
    if (!all(required %in% names(x))) {
      return(FALSE)
    }
    for (name in required) {
      if (!identical(x[[name]], attr(x, name, exact = TRUE))) {
        return(FALSE)
      }
    }
    token <- x$token
    duckdb_sql <- x$duckdb_sql
    kind <- x$kind
    children <- x$children
    child_names <- x$child_names
    size <- x$size
    parameters <- x$parameters
    if (!ok_scalar(token) || !ok_scalar(duckdb_sql) || !ok_scalar(kind) ||
        !is.list(children) || !is.character(child_names) || length(child_names) != length(children) ||
        !is.integer(size) || length(size) != 1L || !is.list(parameters)) {
      return(FALSE)
    }
    n_children <- length(children)
    size_value <- size[[1L]]
    kind_ok <- switch(kind,
      scalar = n_children == 0L,
      decimal = {
        width <- parameters$width
        scale <- parameters$scale
        n_children == 0L && is.na(size_value) && is.integer(width) && length(width) == 1L &&
          is.integer(scale) && length(scale) == 1L && !is.na(width) && !is.na(scale) &&
          width >= 1L && width <= 38L && scale >= 0L && scale <= width
      },
      enum = n_children == 0L && is.na(size_value) && ok_names(parameters$levels),
      list = n_children == 1L && identical(child_names, "child") && is.na(size_value),
      array = n_children == 1L && identical(child_names, "child") && !is.na(size_value) && size_value > 0L,
      struct = n_children > 0L && is.na(size_value) && ok_names(child_names),
      map = n_children == 2L && identical(child_names, c("key", "value")) && is.na(size_value),
      union = n_children > 0L && is.na(size_value) && ok_names(child_names),
      FALSE
    )
    isTRUE(kind_ok) && all(vapply(children, rec, logical(1), depth = depth + 1L))
  }
  rec(x)
}

#' @rdname rducks_type_objects
#' @export
BOOLEAN <- rducks_type_object("bool")
#' @rdname rducks_type_objects
#' @export
TINYINT <- rducks_type_object("i8")
#' @rdname rducks_type_objects
#' @export
UTINYINT <- rducks_type_object("u8")
#' @rdname rducks_type_objects
#' @export
SMALLINT <- rducks_type_object("i16")
#' @rdname rducks_type_objects
#' @export
USMALLINT <- rducks_type_object("u16")
#' @rdname rducks_type_objects
#' @export
INTEGER <- rducks_type_object("i32")
#' @rdname rducks_type_objects
#' @export
UINTEGER <- rducks_type_object("u32")
#' @rdname rducks_type_objects
#' @export
BIGINT <- rducks_type_object("i64")
#' @rdname rducks_type_objects
#' @export
UBIGINT <- rducks_type_object("u64")
#' @rdname rducks_type_objects
#' @export
FLOAT <- rducks_type_object("f32")
#' @rdname rducks_type_objects
#' @export
DOUBLE <- rducks_type_object("f64")
#' @rdname rducks_type_objects
#' @export
VARCHAR <- rducks_type_object("varchar")
#' @rdname rducks_type_objects
#' @export
BLOB <- rducks_type_object("blob")
#' @rdname rducks_type_objects
#' @export
GEOMETRY <- rducks_type_object("geometry")
#' @rdname rducks_type_objects
#' @export
VARIANT <- rducks_type_object("variant")
#' @rdname rducks_type_objects
#' @export
DATE <- rducks_type_object("date")
#' @rdname rducks_type_objects
#' @export
TIME <- rducks_type_object("time")
#' @rdname rducks_type_objects
#' @export
TIMESTAMP <- rducks_type_object("timestamp")
#' @rdname rducks_type_objects
#' @export
HUGEINT <- rducks_type_object("hugeint")
#' @rdname rducks_type_objects
#' @export
UHUGEINT <- rducks_type_object("uhugeint")
#' @rdname rducks_type_objects
#' @export
UUID <- rducks_type_object("uuid")
#' @rdname rducks_type_objects
#' @export
INTERVAL <- rducks_type_object("interval")
#' @rdname rducks_type_objects
#' @export
BIT <- rducks_type_object("bit")

#' @rdname rducks_type_objects
#' @export
DECIMAL <- function(width, scale = 0L) {
  spec <- rducks_check_decimal_spec(width, scale)
  rducks_type_construct_s7(
    token = sprintf("decimal<%d;%d>", spec[["width"]], spec[["scale"]]),
    duckdb_sql = sprintf("DECIMAL(%d, %d)", spec[["width"]], spec[["scale"]]),
    kind = "decimal",
    children = list(),
    child_names = character(),
    size = NA_integer_,
    parameters = list(width = as.integer(spec[["width"]]), scale = as.integer(spec[["scale"]]))
  )
}

#' @rdname rducks_type_objects
#' @export
ENUM <- function(levels) {
  levels <- rducks_type_name_ok(as.character(levels), "levels")
  rducks_type_construct_s7(
    token = sprintf("enum<%s>", rducks_enum_level_token(levels)),
    duckdb_sql = sprintf("ENUM(%s)", paste(vapply(levels, rducks_sql_quote, character(1)), collapse = ", ")),
    kind = "enum",
    children = list(),
    child_names = character(),
    size = NA_integer_,
    parameters = list(levels = levels)
  )
}

#' @rdname rducks_type_objects
#' @export
UNION <- function(...) {
  members <- list(...)
  member_names <- names(members)
  if (!length(members) || is.null(member_names) || any(!nzchar(member_names))) {
    stop("UNION members must be named", call. = FALSE)
  }
  if (anyDuplicated(member_names)) {
    stop("UNION member names must be unique", call. = FALSE)
  }
  if (length(members) > 255L) {
    stop("UNION supports at most 255 members (DuckDB limit)", call. = FALSE)
  }
  members <- lapply(members, function(member) if (rducks_type_inherits(member, "rducks_type")) member else rducks_type_object(member))
  rducks_type_construct_s7(
    token = sprintf(
      "union<%s>",
      paste(sprintf("%s:%s", vapply(member_names, rducks_token_percent_encode, character(1)), vapply(members, rducks_type_token, character(1))), collapse = ";")
    ),
    duckdb_sql = sprintf(
      "UNION(%s)",
      paste(sprintf("%s %s", member_names, vapply(members, rducks_type_duckdb_sql, character(1))), collapse = ", ")
    ),
    kind = "union",
    children = members,
    child_names = member_names,
    size = NA_integer_
  )
}

#' @rdname rducks_type_objects
#' @export
LIST <- function(type) {
  child <- if (rducks_type_inherits(type, "rducks_type")) type else rducks_type_object(type)
  rducks_type_construct_s7(
    token = paste0("list<", rducks_type_token(child), ">"),
    duckdb_sql = paste0(rducks_type_duckdb_sql(child), "[]"),
    kind = "list",
    children = list(child),
    child_names = "child",
    size = NA_integer_
  )
}

#' @rdname rducks_type_objects
#' @export
ARRAY <- function(type, size) {
  if (!is.numeric(size) || length(size) != 1L || is.na(size) || size <= 0 || size != as.integer(size)) {
    stop("size must be a positive integer scalar", call. = FALSE)
  }
  child <- if (rducks_type_inherits(type, "rducks_type")) type else rducks_type_object(type)
  size <- as.integer(size)
  rducks_type_construct_s7(
    token = sprintf("%s[%d]", rducks_type_token(child), size),
    duckdb_sql = sprintf("%s[%d]", rducks_type_duckdb_sql(child), size),
    kind = "array",
    children = list(child),
    child_names = "child",
    size = size
  )
}

#' @rdname rducks_type_objects
#' @export
MAP <- function(key, value) {
  key <- if (rducks_type_inherits(key, "rducks_type")) key else rducks_type_object(key)
  value <- if (rducks_type_inherits(value, "rducks_type")) value else rducks_type_object(value)
  rducks_type_construct_s7(
    token = sprintf("map<%s;%s>", rducks_type_token(key), rducks_type_token(value)),
    duckdb_sql = sprintf("MAP(%s, %s)", rducks_type_duckdb_sql(key), rducks_type_duckdb_sql(value)),
    kind = "map",
    children = list(key, value),
    child_names = c("key", "value"),
    size = NA_integer_
  )
}

#' @rdname rducks_type_objects
#' @export
STRUCT <- function(...) {
  fields <- list(...)
  field_names <- names(fields)
  if (!length(fields) || is.null(field_names) || any(!nzchar(field_names))) {
    stop("STRUCT fields must be named", call. = FALSE)
  }
  fields <- lapply(fields, function(field) if (rducks_type_inherits(field, "rducks_type")) field else rducks_type_object(field))
  rducks_type_construct_s7(
    token = sprintf(
      "struct<%s>",
      paste(sprintf("%s:%s", vapply(field_names, rducks_token_percent_encode, character(1)), vapply(fields, rducks_type_token, character(1))), collapse = ";")
    ),
    duckdb_sql = sprintf(
      "STRUCT(%s)",
      paste(sprintf("%s %s", field_names, vapply(fields, rducks_type_duckdb_sql, character(1))), collapse = ", ")
    ),
    kind = "struct",
    children = fields,
    child_names = field_names,
    size = NA_integer_
  )
}

rducks_variant_storage_type <- function() {
  STRUCT(
    keys = LIST(VARCHAR),
    children = LIST(STRUCT(keys_index = UINTEGER, values_index = UINTEGER)),
    values = LIST(STRUCT(type_id = UTINYINT, byte_offset = UINTEGER)),
    data = BLOB
  )
}

#' Construct a DuckDB VARIANT storage object
#'
#' `VARIANT` values cross the Rducks boundary as DuckDB's typed storage object:
#' a named list with `keys`, `children`, `values`, and `data` fields. Most code
#' receives this object from a VARIANT argument and returns it unchanged or after
#' using DuckDB SQL functions such as `variant_extract()` before crossing into R.
#'
#' @param x Named list in DuckDB VARIANT storage shape.
#' @return `x` with class `rducks_variant` after validation.
#' @examples
#' # VARIANT storage objects are normally produced by DuckDB at the R boundary.
#' # rducks_variant() validates the storage shape; constructing one by hand
#' # requires the full internal DuckDB VARIANT storage layout.
#' @export
rducks_variant <- function(x) {
  rducks_check_value(rducks_variant_storage_type(), x, what = "variant value")
  structure(x, class = c("rducks_variant", setdiff(class(x), "rducks_variant")))
}

rducks_type_parameter_summary <- function(x) {
  params <- rducks_type_parameters(x)
  kind <- rducks_type_kind(x)
  if (!length(params)) return(character())
  if (identical(kind, "decimal")) {
    return(sprintf("width=%d, scale=%d", params$width, params$scale))
  }
  if (identical(kind, "enum")) {
    return(sprintf("levels=%s", paste(params$levels, collapse = ",")))
  }
  paste(sprintf("%s=%s", names(params), vapply(params, paste, character(1), collapse = ",")), collapse = "; ")
}

rducks_register_type_s7_methods <- function() {
  S7::method(format, rducks_type_class) <- function(x, ...) rducks_type_sql(x)

  S7::method(as.character, rducks_type_class) <- function(x, ...) rducks_type_sql(x)

  S7::method(length, rducks_type_class) <- function(x) 1L

  S7::method(print, rducks_type_class) <- function(x, ...) {
    cat("<rducks_type:", rducks_type_kind(x), "> ", rducks_type_sql(x), "\n", sep = "")
    params <- rducks_type_parameter_summary(x)
    if (length(params) && nzchar(params)) {
      cat("  parameters: ", params, "\n", sep = "")
    }
    children <- rducks_type_children(x)
    if (length(children)) {
      child_names <- rducks_type_child_names(x)
      cat("  children:\n")
      for (i in seq_along(children)) {
        cat("    ", child_names[[i]], ": ", rducks_type_sql(children[[i]]), "\n", sep = "")
      }
    }
    invisible(x)
  }

  S7::method(c, rducks_type_class) <- function(..., recursive = FALSE) {
    out <- list(...)
    if (!all(vapply(out, rducks_type_descriptor_inherits, logical(1), class = rducks_type_class))) {
      stop("all values must be rducks_type descriptors", call. = FALSE)
    }
    rducks_type_list_class(out)
  }

  S7::method(print, rducks_type_list_class) <- function(x, ...) {
    cat("<rducks_type_list[", length(x), "]>\n", sep = "")
    for (i in seq_along(x)) {
      cat("  ", i, ": ", rducks_type_sql(x[[i]]), "\n", sep = "")
    }
    invisible(x)
  }

  S7::method(`[`, rducks_type_class) <- function(x, i, ...) {
    if (missing(i)) {
      return(LIST(x))
    }
    ARRAY(x, i)
  }

  invisible(NULL)
}

rducks_scalar_argument_mapping_row <- function(token) {
  token <- rducks_type_normalize_scalar(token)
  row <- rducks_scalar_type_row(token)
  row$type_token <- NULL
  row
}

rducks_scalar_vector_description <- function(token, len = NULL) {
  token <- rducks_type_normalize(token)
  desc <- switch(token,
    bool = "logical vector",
    i8 = "integer vector",
    u8 = "integer vector",
    i16 = "integer vector",
    u16 = "integer vector",
    i32 = "integer vector",
    u32 = "numeric vector",
    i64 = "rducks_bigint vector",
    u64 = "rducks_ubigint vector",
    f32 = "numeric vector",
    f64 = "numeric vector",
    varchar = "character vector",
    blob = "list of raw vectors",
    geometry = "list of raw WKB geometry vectors",
    variant = "list of rducks_variant storage objects",
    date = "Date vector",
    time = "numeric vector seconds",
    timestamp = "POSIXct vector",
    hugeint = "rducks_hugeint vector",
    uhugeint = "rducks_uhugeint vector",
    uuid = "rducks_uuid vector",
    interval = "rducks_interval vector",
    bit = "list of rducks_bits values",
    stop("not a scalar type: ", token, call. = FALSE)
  )
  if (!is.null(len) && !token %in% c("blob", "geometry", "variant")) {
    desc <- paste(desc, "of length", len)
  } else if (!is.null(len) && token %in% c("blob", "geometry", "variant")) {
    desc <- paste(desc, "of length", len)
  }
  desc
}

rducks_sequence_value_description <- function(child, len = NULL) {
  child_type <- if (rducks_type_inherits(child, "rducks_type")) child else rducks_type_object(child)
  if (identical(rducks_type_kind(child_type), "scalar")) {
    return(rducks_scalar_vector_description(rducks_type_token(child_type), len = len))
  }
  if (is.null(len)) "list of element values" else paste("list of length", len)
}

rducks_scalar_mapping_supported <- function(type) {
  type <- if (rducks_type_inherits(type, "rducks_type")) type else rducks_type_object(type)
  kind <- rducks_type_kind(type)
  if (identical(kind, "scalar")) {
    return(rducks_type_token(type) %in% rducks_all_scalar_type_names())
  }
  if (kind %in% c("decimal", "enum")) {
    return(TRUE)
  }
  if (kind %in% c("list", "array", "struct", "map", "union")) {
    return(all(vapply(rducks_type_children(type), rducks_scalar_mapping_supported, logical(1))))
  }
  FALSE
}

rducks_direct_sequence_child_supported <- function(type) {
  type <- if (rducks_type_inherits(type, "rducks_type")) type else rducks_type_object(type)
  kind <- rducks_type_kind(type)
  if (kind %in% c("decimal", "enum")) {
    return(TRUE)
  }
  if (kind %in% c("list", "array", "struct", "map", "union")) {
    return(rducks_direct_mapping_supported(type))
  }
  identical(kind, "scalar") && rducks_type_token(type) %in% c(
    "bool", "i8", "u8", "i16", "u16", "i32", "u32",
    "f32", "f64", "varchar", "date", "time", "timestamp"
  )
}

# Runtime capability cache. VARIANT support is conditional: the loaded DuckDB
# build must expose a creatable VARIANT logical type in its C API, and the
# extension must implement VARIANT materialization. The extension reports the
# combined capability via the native rducks_variant_supported() surface; Rducks
# caches it at rducks_enable(). The direct-scalar mapping gate
# (rducks_direct_mapping_supported) and the aggregate gate
# (rducks_assert_variant_materializable) consult it; the wire (ipc) path rejects
# VARIANT unconditionally (rducks_wire_supported_scalar_types omits it), since
# the wire codec has no VARIANT support either. A session links one DuckDB
# build, so a single process-level flag is sufficient. The default (unset ->
# FALSE) keeps VARIANT rejected when capability is unknown, so standalone gate
# calls and runtimes without VARIANT (e.g. 1.5.2) stay safe.
rducks_runtime_caps <- new.env(parent = emptyenv())

rducks_cache_variant_runtime_support <- function(con) {
  supported <- tryCatch(
    isTRUE(DBI::dbGetQuery(con, "SELECT rducks_variant_supported() AS ok")$ok[[1L]]),
    error = function(e) FALSE
  )
  rducks_runtime_caps$variant <- supported
  invisible(supported)
}

rducks_variant_runtime_supported <- function() {
  isTRUE(rducks_runtime_caps$variant)
}

# Recursively detect VARIANT anywhere in a (possibly nested) type.
rducks_type_contains_variant <- function(type) {
  type <- if (rducks_type_inherits(type, "rducks_type")) type else rducks_type_object(type)
  if (identical(rducks_type_kind(type), "scalar") && identical(rducks_type_token(type), "variant")) {
    return(TRUE)
  }
  children <- tryCatch(rducks_type_children(type), error = function(e) list())
  length(children) > 0L && any(vapply(children, rducks_type_contains_variant, logical(1)))
}

# Registration paths that do not run through the execution-plan type gates (e.g.
# aggregates) must still reject VARIANT until the runtime reports VARIANT
# materialization support, so VARIANT is refused consistently everywhere rather
# than registering and then failing at execution on a VARIANT-capable runtime.
rducks_assert_variant_materializable <- function(types, what) {
  if (rducks_variant_runtime_supported()) {
    return(invisible(NULL))
  }
  bad <- types[vapply(types, rducks_type_contains_variant, logical(1))]
  if (length(bad)) {
    stop("DuckDB ", what, " VARIANT marshalling is not implemented for: ",
         paste(unique(vapply(bad, rducks_type_duckdb_sql, character(1))), collapse = ", "),
         call. = FALSE)
  }
  invisible(NULL)
}

rducks_direct_mapping_supported <- function(type) {
  type <- if (rducks_type_inherits(type, "rducks_type")) type else rducks_type_object(type)
  kind <- rducks_type_kind(type)
  if (kind %in% c("decimal", "enum")) {
    return(TRUE)
  }
  if (identical(kind, "scalar")) {
    names <- rducks_all_scalar_type_names()
    if (!rducks_variant_runtime_supported()) names <- setdiff(names, "variant")
    return(rducks_type_token(type) %in% names)
  }
  if (kind %in% c("list", "array")) {
    return(rducks_direct_sequence_child_supported(rducks_type_children(type)[[1L]]))
  }
  if (identical(kind, "struct")) {
    children <- rducks_type_children(type)
    return(length(children) > 0L && all(vapply(children, rducks_direct_mapping_supported, logical(1))))
  }
  if (identical(kind, "map")) {
    children <- rducks_type_children(type)
    return(rducks_direct_sequence_child_supported(children[[1L]]) &&
      rducks_direct_sequence_child_supported(children[[2L]]))
  }
  if (identical(kind, "union")) {
    children <- rducks_type_children(type)
    return(length(children) > 0L && length(children) <= 255L &&
      all(vapply(children, rducks_direct_mapping_supported, logical(1))))
  }
  FALSE
}

rducks_direct_unsupported_types <- function(type) {
  type <- if (rducks_type_inherits(type, "rducks_type")) type else rducks_type_object(type)
  if (rducks_direct_mapping_supported(type)) character() else rducks_type_duckdb_sql(type)
}

rducks_unsupported_duckdb_types <- function(type) {
  type <- if (rducks_type_inherits(type, "rducks_type")) type else rducks_type_object(type)
  if (rducks_scalar_mapping_supported(type)) {
    return(character())
  }
  children <- rducks_type_children(type)
  if (length(children)) {
    out <- unique(unlist(lapply(children, rducks_unsupported_duckdb_types), use.names = FALSE))
    if (length(out)) return(out)
  }
  rducks_type_duckdb_sql(type)
}

rducks_composite_argument_mapping_row <- function(token) {
  type <- if (rducks_type_inherits(token, "rducks_type")) token else rducks_type_object(token)
  token <- rducks_type_token(type)
  kind <- rducks_type_kind(type)
  unsupported <- rducks_unsupported_duckdb_types(type)
  if (length(unsupported)) {
    stop("DuckDB scalar-UDF argument marshalling is not available for ", paste(unsupported, collapse = ", "), call. = FALSE)
  }
  children <- rducks_type_children(type)
  duckdb_sql <- rducks_type_duckdb_sql(type)
  r_value <- switch(kind,
    list = rducks_sequence_value_description(children[[1L]]),
    array = rducks_sequence_value_description(children[[1L]], len = rducks_type_size(type)),
    struct = "named list of fields",
    map = sprintf(
      "list(keys = %s, values = %s)",
      rducks_sequence_value_description(children[[1L]]),
      rducks_sequence_value_description(children[[2L]])
    ),
    decimal = "rducks_decimal scalar",
    enum = "rducks_enum scalar",
    union = "rducks_union object",
    stop("unsupported argument kind: ", kind, call. = FALSE)
  )
  r_type <- switch(kind,
    list = if (identical(rducks_type_kind(children[[1L]]), "scalar")) "vector" else "list",
    array = if (identical(rducks_type_kind(children[[1L]]), "scalar")) "vector" else "list",
    struct = "list",
    map = "list",
    decimal = "rducks_decimal",
    enum = "rducks_enum",
    union = "rducks_union",
    "list"
  )
  notes <- switch(kind,
    list = "homogeneous scalar children use atomic vectors",
    array = "fixed-size array; homogeneous scalar children use atomic vectors",
    struct = "recursive field mapping",
    map = "keys and values use sequence mapping",
    decimal = "exact fixed-point value class",
    enum = "factor with enum levels",
    union = "tagged value object",
    ""
  )
  leaves <- unique(rducks_type_scalar_leaves(type))
  unsupported_leaves <- leaves[!leaves %in% rducks_all_scalar_type_names()]
  if (length(unsupported_leaves)) {
    stop(
      "DuckDB scalar-UDF argument marshalling is not available for ",
      paste(vapply(unsupported_leaves, rducks_scalar_duckdb_sql, character(1)), collapse = ", "),
      call. = FALSE
    )
  }
  leaf_rows <- if (length(leaves)) do.call(rbind, lapply(leaves, rducks_scalar_argument_mapping_row)) else NULL
  data.frame(
    duckdb_type = duckdb_sql,
    descriptor_kind = kind,
    r_value_class = r_type,
    r_argument_shape = r_value,
    special_null_argument = "NULL",
    copy_semantics = if (kind %in% c("decimal", "enum", "union")) "boxed exact Rducks value" else if (identical(r_type, "vector")) "R vector allocation" else "recursive R allocation",
    integer_uses_r_double = if (is.null(leaf_rows)) FALSE else any(leaf_rows$integer_uses_r_double),
    float32_widens_to_r_double = if (is.null(leaf_rows)) FALSE else any(leaf_rows$float32_widens_to_r_double),
    precision_may_be_lost = if (is.null(leaf_rows)) FALSE else any(leaf_rows$precision_may_be_lost),
    notes = notes,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

rducks_check_argument_type_mapping <- function(mapping) {
  required <- c(
    "duckdb_type", "descriptor_kind", "r_value_class", "r_argument_shape",
    "special_null_argument", "copy_semantics", "integer_uses_r_double",
    "float32_widens_to_r_double", "precision_may_be_lost", "notes"
  )
  missing <- setdiff(required, names(mapping))
  if (length(missing)) {
    stop("argument type mapping is missing columns: ", paste(missing, collapse = ", "), call. = FALSE)
  }
  invisible(TRUE)
}

#' Describe how Rducks argument values are passed to R functions
#'
#' `rducks_argument_type_mapping()` is the package-level source of truth for the
#' R value shape used when DuckDB argument values are marshalled into an R
#' function call. It is used by scalar-UDF registration checks and the
#' direct native marshalling adapter.
#'
#' With `null_handling = "default"`, top-level SQL `NULL` inputs short-circuit
#' to a SQL `NULL` result and the R function is not called. The
#' `special_null_argument` column describes the value passed only when
#' `null_handling = "special"`. This value is type-specific: ordinary R scalar
#' types receive typed `NA` values, while exact Rducks value classes, binary
#' values, and top-level composite values receive R `NULL`. Within homogeneous
#' scalar lists/arrays, SQL `NULL` elements are represented as typed `NA` values
#' where the child type has an R `NA` representation; nested composite `NULL`
#' values are represented as R `NULL`.
#'
#' The default table contains all scalar descriptors supported by the direct
#' scalar-UDF marshalling adapter. `DECIMAL`, `ENUM`, `UNION`, and composite
#' descriptors can be requested explicitly to inspect their recursive R function
#' shapes.
#'
#' @param x Optional scalar type tokens or constructed `rducks_type` descriptors.
#'   When `NULL`, all currently implemented DuckDB scalar-UDF scalar argument
#'   mappings are returned. Composite mappings should be requested with constructors such
#'   as `INTEGER[]`, `INTEGER[3]`, `STRUCT(a = INTEGER)`, and
#'   `MAP(VARCHAR, INTEGER)`.
#' @return A data frame with one row per requested type descriptor.
#' @examples
#' rducks_argument_type_mapping()
#' rducks_argument_type_mapping(INTEGER)
#' rducks_argument_type_mapping(STRUCT(a = INTEGER, b = VARCHAR))
#' @export
rducks_argument_type_mapping <- function(x = NULL) {
  items <- if (is.null(x)) {
    as.list(rducks_all_scalar_type_names())
  } else if (rducks_type_inherits(x, "rducks_type")) {
    list(x)
  } else {
    rducks_as_type_list(x)
  }
  rows <- lapply(items, function(item) {
    type <- if (rducks_type_inherits(item, "rducks_type")) item else rducks_type_object(item)
    if (identical(rducks_type_kind(type), "scalar")) {
      rducks_scalar_argument_mapping_row(rducks_type_token(type))
    } else {
      rducks_composite_argument_mapping_row(type)
    }
  })
  out <- if (length(rows)) do.call(rbind, rows) else {
    data.frame(
      duckdb_type = character(), descriptor_kind = character(), r_value_class = character(),
      r_argument_shape = character(), special_null_argument = character(),
      copy_semantics = character(), integer_uses_r_double = logical(),
      float32_widens_to_r_double = logical(), precision_may_be_lost = logical(),
      notes = character(), stringsAsFactors = FALSE, check.names = FALSE
    )
  }
  row.names(out) <- NULL
  rducks_check_argument_type_mapping(out)
  out
}

#' Convert Rducks type descriptors to DuckDB SQL types
#'
#' @param x Character scalar tokens, `rducks_type` descriptors, or a list of descriptors.
#' @return Character vector of DuckDB SQL type names.
#' @examples
#' rducks_duckdb_types(INTEGER)
#' rducks_duckdb_types(c(INTEGER, DOUBLE, VARCHAR))
#' rducks_duckdb_types(STRUCT(a = INTEGER, b = VARCHAR))
#' @export
rducks_duckdb_types <- function(x) {
  types <- rducks_as_type_list(x)
  vapply(types, rducks_duckdb_type_one, character(1), USE.NAMES = FALSE)
}

#' Format a DuckDB scalar function signature
#'
#' @param name SQL function name.
#' @param args Argument type descriptors.
#' @param returns Return type descriptor.
#' @return Character scalar signature such as `f(INTEGER) -> DOUBLE`.
#' @examples
#' rducks_duckdb_signature("my_udf", c(INTEGER, VARCHAR), DOUBLE)
#' @export
rducks_duckdb_signature <- function(name, args, returns) {
  rducks_assert_non_empty_character_scalar(name, "name")
  arg_sql <- paste(rducks_duckdb_types(args), collapse = ", ")
  ret_sql <- rducks_duckdb_types(returns)
  sprintf("%s(%s) -> %s", name, arg_sql, ret_sql)
}
