rducks_scalar_type_table <- data.frame(
  rducks_type = c(
    "bool", "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64",
    "f32", "f64", "varchar", "blob", "date", "time", "timestamp",
    "hugeint", "uhugeint", "uuid", "interval", "bit"
  ),
  duckdb_sql = c(
    "BOOLEAN", "TINYINT", "UTINYINT", "SMALLINT", "USMALLINT", "INTEGER", "UINTEGER",
    "BIGINT", "UBIGINT", "FLOAT", "DOUBLE", "VARCHAR", "BLOB", "DATE", "TIME", "TIMESTAMP",
    "HUGEINT", "UHUGEINT", "UUID", "INTERVAL", "BIT"
  ),
  argument_kind = c(rep("scalar", 16L), rep("exotic", 5L)),
  r_type = c(
    "logical", "integer", "integer", "integer", "integer", "integer", "numeric",
    "rducks_bigint", "rducks_ubigint", "numeric", "numeric", "character", "raw",
    "Date", "numeric", "POSIXct", "rducks_hugeint", "rducks_uhugeint",
    "rducks_uuid", "rducks_interval", "rducks_bits"
  ),
  r_value_passed_to_fun = c(
    "logical(1)", "integer(1)", "integer(1)", "integer(1)", "integer(1)", "integer(1)",
    "numeric(1)", "rducks_bigint scalar", "rducks_ubigint scalar", "numeric(1)",
    "numeric(1)", "character(1)", "raw vector", "Date scalar", "numeric(1) seconds",
    "POSIXct scalar", "rducks_hugeint", "rducks_uhugeint", "rducks_uuid",
    "rducks_interval", "rducks_bits"
  ),
  sql_null_in_function = c(
    "NA", rep("NA_integer_", 5L), "NA_real_", "NULL", "NULL", "NA_real_", "NA_real_",
    "NA_character_", "NULL", "NA_real_ (unclassed)", "NA_real_", "NA_real_ (unclassed)",
    rep("NULL", 5L)
  ),
  copy_semantics = c(
    rep("boxed scalar", 11L), "string copied into R", "bytes copied into R", rep("boxed scalar", 3L),
    rep("boxed exact Rducks value object", 5L)
  ),
  uses_r_double_for_integer = c(rep(FALSE, 6L), TRUE, rep(FALSE, 14L)),
  uses_r_double_for_float = c(rep(FALSE, 9L), TRUE, rep(FALSE, 11L)),
  precision_may_be_lost = FALSE,
  notes = c(
    "", "", "", "", "", "", "R double", "exact signed 64-bit integer string",
    "exact unsigned 64-bit integer string", "widened to R double", "", "string copied into R",
    "bytes copied into R", "days since 1970-01-01", "microseconds converted to seconds",
    "microseconds converted to seconds", rep("exact Rducks value class", 5L)
  ),
  stringsAsFactors = FALSE,
  check.names = FALSE
)

rducks_scalar_type_row <- function(token) {
  token <- rducks_type_normalize_scalar(token)
  row <- rducks_scalar_type_table[rducks_scalar_type_table$rducks_type == token, , drop = FALSE]
  row.names(row) <- NULL
  row
}

rducks_all_scalar_type_names <- function() {
  rducks_scalar_type_table$rducks_type
}

rducks_type_normalize_scalar <- function(token, original = token) {
  token <- tolower(trimws(token))
  if (!token %in% rducks_all_scalar_type_names()) {
    stop("unsupported scalar Rducks type token: ", original, call. = FALSE)
  }
  token
}

rducks_scalar_duckdb_sql <- function(token) {
  rducks_scalar_type_row(token)$duckdb_sql[[1L]]
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
#' constructed `rducks_type` objects rather than quoted type strings.
#'
#' @param x Character scalar scalar-type token or a `rducks_type` object.
#' @return Canonical scalar token for character input, or the object's wire
#'   token for a `rducks_type`.
#' @export
rducks_type_normalize <- function(x) {
  if (inherits(x, "rducks_type")) {
    return(rducks_type_token(x))
  }
  if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x)) {
    stop("type must be a non-empty scalar token or rducks_type object", call. = FALSE)
  }
  chars <- strsplit(x, "", fixed = TRUE)[[1L]]
  if (any(chars %in% c("<", ">", "[", "]", "(", ")", ":", ";", ","))) {
    rducks_reject_character_composite_type(x)
  }
  rducks_type_normalize_scalar(x, x)
}

rducks_as_type <- function(x) {
  if (inherits(x, "rducks_type")) {
    return(x)
  }
  rducks_type_object(x)
}

rducks_as_type_list <- function(x) {
  if (inherits(x, "rducks_type")) {
    return(list(x))
  }
  if (inherits(x, "rducks_type_list") || is.list(x)) {
    if (!all(vapply(x, inherits, logical(1), what = "rducks_type"))) {
      stop("type lists must contain only rducks_type objects", call. = FALSE)
    }
    return(unclass(x))
  }
  if (is.character(x)) {
    return(lapply(x, rducks_type_object))
  }
  stop("types must be scalar tokens, a rducks_type object, or a list of rducks_type objects", call. = FALSE)
}

rducks_type_scalar_leaves <- function(type) {
  if (!inherits(type, "rducks_type")) {
    type <- rducks_type_object(type)
  }
  if (identical(rducks_type_kind(type), "scalar")) {
    return(rducks_type_token(type))
  }
  unlist(lapply(rducks_type_children(type), rducks_type_scalar_leaves), use.names = FALSE)
}

rducks_duckdb_type_one <- function(type) {
  if (inherits(type, "rducks_type")) {
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
  paste(levels, collapse = "|")
}

#' Rducks DuckDB type objects and constructors
#'
#' Use these objects and constructors in [rducks_register()] to avoid string type
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
#' @param ... Named field types for `STRUCT()`/`UNION()` or type objects for `c()`.
#' @param x Object to test with `rducks_is_type()`.
#' @return A formal S7/S3-compatible `rducks_type` object, or a
#'   `rducks_type_list` from `c()`.
#' @name rducks_type_objects
NULL

#' @rdname rducks_type_objects
#' @export
rducks_is_type <- function(x) {
  ok_scalar <- function(value) is.character(value) && length(value) == 1L && !is.na(value) && nzchar(value)
  ok_names <- function(value) is.character(value) && length(value) > 0L && !anyNA(value) && all(nzchar(value)) && !anyDuplicated(value)
  rec <- function(x, depth = 0L) {
    if (depth > 64L || !inherits(x, "rducks_type") || !inherits(x, "S7_object") || !is.list(x)) {
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
  members <- lapply(members, function(member) if (inherits(member, "rducks_type")) member else rducks_type_object(member))
  rducks_type_construct_s7(
    token = sprintf(
      "union<%s>",
      paste(sprintf("%s:%s", member_names, vapply(members, rducks_type_token, character(1))), collapse = ";")
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
  child <- if (inherits(type, "rducks_type")) type else rducks_type_object(type)
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
  child <- if (inherits(type, "rducks_type")) type else rducks_type_object(type)
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
  key <- if (inherits(key, "rducks_type")) key else rducks_type_object(key)
  value <- if (inherits(value, "rducks_type")) value else rducks_type_object(value)
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
  fields <- lapply(fields, function(field) if (inherits(field, "rducks_type")) field else rducks_type_object(field))
  rducks_type_construct_s7(
    token = sprintf(
      "struct<%s>",
      paste(sprintf("%s:%s", field_names, vapply(fields, rducks_type_token, character(1))), collapse = ";")
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

#' @export
format.rducks_type <- function(x, ...) rducks_type_sql(x)

#' @export
as.character.rducks_type <- function(x, ...) rducks_type_sql(x)

#' @export
length.rducks_type <- function(x) 1L

#' @export
print.rducks_type <- function(x, ...) {
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

#' @export
c.rducks_type <- function(..., recursive = FALSE) {
  out <- list(...)
  if (!all(vapply(out, inherits, logical(1), what = "rducks_type"))) {
    stop("all values must be rducks_type objects", call. = FALSE)
  }
  rducks_type_list_class(out)
}

#' @export
print.rducks_type_list <- function(x, ...) {
  cat("<rducks_type_list[", length(x), "]>\n", sep = "")
  for (i in seq_along(x)) {
    cat("  ", i, ": ", rducks_type_sql(x[[i]]), "\n", sep = "")
  }
  invisible(x)
}

#' @export
`[.rducks_type` <- function(x, i, ...) {
  if (missing(i)) {
    return(LIST(x))
  }
  ARRAY(x, i)
}

rducks_scalar_argument_mapping_row <- function(token) {
  token <- rducks_type_normalize_scalar(token)
  rducks_scalar_type_row(token)
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
  if (!is.null(len) && !identical(token, "blob")) {
    desc <- paste(desc, "of length", len)
  } else if (!is.null(len) && identical(token, "blob")) {
    desc <- paste(desc, "of length", len)
  }
  desc
}

rducks_sequence_value_description <- function(child, len = NULL) {
  child_type <- if (inherits(child, "rducks_type")) child else rducks_type_object(child)
  if (identical(rducks_type_kind(child_type), "scalar")) {
    return(rducks_scalar_vector_description(rducks_type_token(child_type), len = len))
  }
  if (is.null(len)) "list of element values" else paste("list of length", len)
}

rducks_scalar_mapping_supported <- function(type) {
  type <- if (inherits(type, "rducks_type")) type else rducks_type_object(type)
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

rducks_unsupported_duckdb_types <- function(type) {
  type <- if (inherits(type, "rducks_type")) type else rducks_type_object(type)
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
  type <- if (inherits(token, "rducks_type")) token else rducks_type_object(token)
  token <- rducks_type_token(type)
  kind <- rducks_type_kind(type)
  unsupported <- rducks_unsupported_duckdb_types(type)
  if (length(unsupported)) {
    stop("scalar-mode argument marshalling is not available for ", paste(unsupported, collapse = ", "), call. = FALSE)
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
      "scalar-mode argument marshalling is not available for ",
      paste(vapply(unsupported_leaves, rducks_scalar_duckdb_sql, character(1)), collapse = ", "),
      call. = FALSE
    )
  }
  leaf_rows <- if (length(leaves)) do.call(rbind, lapply(leaves, rducks_scalar_argument_mapping_row)) else NULL
  data.frame(
    rducks_type = token,
    duckdb_sql = duckdb_sql,
    argument_kind = kind,
    r_type = r_type,
    r_value_passed_to_fun = r_value,
    sql_null_in_function = "NULL",
    copy_semantics = if (kind %in% c("decimal", "enum", "union")) "boxed exact Rducks value object" else if (identical(r_type, "vector")) "R vector allocation" else "recursive R allocation",
    uses_r_double_for_integer = if (is.null(leaf_rows)) FALSE else any(leaf_rows$uses_r_double_for_integer),
    uses_r_double_for_float = if (is.null(leaf_rows)) FALSE else any(leaf_rows$uses_r_double_for_float),
    precision_may_be_lost = if (is.null(leaf_rows)) FALSE else any(leaf_rows$precision_may_be_lost),
    notes = notes,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

rducks_check_argument_type_mapping <- function(mapping) {
  required <- c(
    "rducks_type", "duckdb_sql", "argument_kind", "r_type",
    "r_value_passed_to_fun", "sql_null_in_function", "copy_semantics",
    "uses_r_double_for_integer", "uses_r_double_for_float", "precision_may_be_lost",
    "notes"
  )
  missing <- setdiff(required, names(mapping))
  if (length(missing)) {
    stop("argument type mapping is missing columns: ", paste(missing, collapse = ", "), call. = FALSE)
  }
  if (nrow(mapping)) {
    for (i in seq_len(nrow(mapping))) {
      token <- mapping$rducks_type[[i]]
      if (!token %in% rducks_all_scalar_type_names() || !mapping$argument_kind[[i]] %in% c("scalar", "exotic")) {
        next
      }
      row <- rducks_scalar_type_row(token)
      if (!identical(mapping$duckdb_sql[[i]], row$duckdb_sql[[1L]])) {
        stop("DuckDB SQL mapping mismatch for scalar type: ", token, call. = FALSE)
      }
      if (!identical(mapping$r_type[[i]], row$r_type[[1L]])) {
        stop("R type mapping mismatch for scalar type: ", token, call. = FALSE)
      }
    }
  }
  invisible(TRUE)
}

#' Describe how Rducks argument values are passed to R functions
#'
#' `rducks_argument_type_mapping()` is the package-level source of truth for the
#' R value shape used when DuckDB argument values are marshalled into an R
#' function call. It is used by registration checks and the nanoarrow scalar
#' marshalling adapter.
#'
#' With `null_handling = "default"`, top-level SQL `NULL` inputs short-circuit
#' to a SQL `NULL` result and the R function is not called. The
#' `sql_null_in_function` column describes the value passed only when
#' `null_handling = "special"`. This value is type-specific: ordinary R scalar
#' types receive typed `NA` values, while exact/exotic value classes, binary
#' values, and top-level composite values receive R `NULL`. Within homogeneous
#' scalar lists/arrays, SQL `NULL` elements are represented as typed `NA` values
#' where the child type has an R `NA` representation; nested composite `NULL`
#' values are represented as R `NULL`.
#'
#' The default table contains all scalar types supported by the nanoarrow scalar
#' marshalling adapter. `DECIMAL`, `ENUM`, `UNION`, and composite
#' descriptors can be requested explicitly to inspect their recursive R
#' R function shapes.
#'
#' @param x Optional scalar type tokens or constructed `rducks_type` objects.
#'   When `NULL`, all currently implemented scalar-mode scalar argument mappings
#'   are returned. Composite mappings should be requested with constructors such
#'   as `INTEGER[]`, `INTEGER[3]`, `STRUCT(a = INTEGER)`, and
#'   `MAP(VARCHAR, INTEGER)`.
#' @return A data frame with one row per requested type token.
#' @export
rducks_argument_type_mapping <- function(x = NULL) {
  items <- if (is.null(x)) {
    as.list(rducks_all_scalar_type_names())
  } else if (inherits(x, "rducks_type")) {
    list(x)
  } else {
    rducks_as_type_list(x)
  }
  rows <- lapply(items, function(item) {
    type <- if (inherits(item, "rducks_type")) item else rducks_type_object(item)
    if (identical(rducks_type_kind(type), "scalar")) {
      rducks_scalar_argument_mapping_row(rducks_type_token(type))
    } else {
      rducks_composite_argument_mapping_row(type)
    }
  })
  out <- if (length(rows)) do.call(rbind, rows) else {
    data.frame(
      rducks_type = character(), duckdb_sql = character(), argument_kind = character(),
      r_type = character(), r_value_passed_to_fun = character(),
      sql_null_in_function = character(), copy_semantics = character(),
      uses_r_double_for_integer = logical(), uses_r_double_for_float = logical(),
      precision_may_be_lost = logical(), notes = character(),
      stringsAsFactors = FALSE, check.names = FALSE
    )
  }
  row.names(out) <- NULL
  rducks_check_argument_type_mapping(out)
  out
}

#' Convert Rducks type tokens to DuckDB SQL types
#'
#' @param x Character vector of type tokens.
#' @return Character vector of DuckDB SQL type names.
#' @export
rducks_duckdb_types <- function(x) {
  types <- rducks_as_type_list(x)
  vapply(types, rducks_duckdb_type_one, character(1), USE.NAMES = FALSE)
}

#' Format a DuckDB scalar function signature
#'
#' @param name SQL function name.
#' @param args Argument type tokens.
#' @param returns Return type token.
#' @return Character scalar signature such as `f(INTEGER) -> DOUBLE`.
#' @export
rducks_duckdb_signature <- function(name, args, returns) {
  if (!is.character(name) || length(name) != 1L || !nzchar(name)) {
    stop("name must be a non-empty character scalar", call. = FALSE)
  }
  arg_sql <- paste(rducks_duckdb_types(args), collapse = ", ")
  ret_sql <- rducks_duckdb_types(returns)
  sprintf("%s(%s) -> %s", name, arg_sql, ret_sql)
}
