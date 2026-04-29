rducks_scalar_types <- local({
  table <- list(
    bool = list(c = "bool", duckdb = "BOOLEAN", r = "logical"),
    i8 = list(c = "int8_t", duckdb = "TINYINT", r = "integer"),
    u8 = list(c = "uint8_t", duckdb = "UTINYINT", r = "integer"),
    i16 = list(c = "int16_t", duckdb = "SMALLINT", r = "integer"),
    u16 = list(c = "uint16_t", duckdb = "USMALLINT", r = "integer"),
    i32 = list(c = "int32_t", duckdb = "INTEGER", r = "integer"),
    u32 = list(c = "uint32_t", duckdb = "UINTEGER", r = "numeric"),
    i64 = list(c = "int64_t", duckdb = "BIGINT", r = "rducks_bigint"),
    u64 = list(c = "uint64_t", duckdb = "UBIGINT", r = "rducks_ubigint"),
    f32 = list(c = "float", duckdb = "FLOAT", r = "numeric"),
    f64 = list(c = "double", duckdb = "DOUBLE", r = "numeric"),
    varchar = list(c = "const char *", duckdb = "VARCHAR", r = "character"),
    blob = list(c = "rducks_blob_t", duckdb = "BLOB", r = "raw"),
    date = list(c = "rducks_date_t", duckdb = "DATE", r = "Date"),
    time = list(c = "rducks_time_t", duckdb = "TIME", r = "numeric"),
    timestamp = list(c = "rducks_timestamp_t", duckdb = "TIMESTAMP", r = "POSIXct")
  )
  aliases <- c(
    logical = "bool",
    boolean = "bool",
    tinyint = "i8",
    int8 = "i8",
    byte = "i8",
    utinyint = "u8",
    uint8 = "u8",
    unsigned_byte = "u8",
    smallint = "i16",
    int16 = "i16",
    usmallint = "u16",
    uint16 = "u16",
    int = "i32",
    integer = "i32",
    int32 = "i32",
    uint = "u32",
    uint32 = "u32",
    uinteger = "u32",
    int64 = "i64",
    bigint = "i64",
    uint64 = "u64",
    ubigint = "u64",
    float = "f32",
    double = "f64",
    numeric = "f64",
    real = "f64",
    string = "varchar",
    character = "varchar",
    cstring = "varchar",
    raw = "blob",
    binary = "blob",
    posixct = "timestamp",
    datetime = "timestamp"
  )
  list(table = table, aliases = aliases)
})

rducks_scalar_argument_mapping_specs <- list(
  bool = list(
    r_value = "logical(1)", sql_null = "NA", copy = "boxed scalar",
    notes = "", uses_r_double_for_integer = FALSE, uses_r_double_for_float = FALSE,
    precision_may_be_lost = FALSE
  ),
  i8 = list(
    r_value = "integer(1)", sql_null = "NA_integer_", copy = "boxed scalar",
    notes = "", uses_r_double_for_integer = FALSE, uses_r_double_for_float = FALSE,
    precision_may_be_lost = FALSE
  ),
  u8 = list(
    r_value = "integer(1)", sql_null = "NA_integer_", copy = "boxed scalar",
    notes = "", uses_r_double_for_integer = FALSE, uses_r_double_for_float = FALSE,
    precision_may_be_lost = FALSE
  ),
  i16 = list(
    r_value = "integer(1)", sql_null = "NA_integer_", copy = "boxed scalar",
    notes = "", uses_r_double_for_integer = FALSE, uses_r_double_for_float = FALSE,
    precision_may_be_lost = FALSE
  ),
  u16 = list(
    r_value = "integer(1)", sql_null = "NA_integer_", copy = "boxed scalar",
    notes = "", uses_r_double_for_integer = FALSE, uses_r_double_for_float = FALSE,
    precision_may_be_lost = FALSE
  ),
  i32 = list(
    r_value = "integer(1)", sql_null = "NA_integer_", copy = "boxed scalar",
    notes = "", uses_r_double_for_integer = FALSE, uses_r_double_for_float = FALSE,
    precision_may_be_lost = FALSE
  ),
  u32 = list(
    r_value = "numeric(1)", sql_null = "NA_real_", copy = "boxed scalar",
    notes = "R double", uses_r_double_for_integer = TRUE, uses_r_double_for_float = FALSE,
    precision_may_be_lost = FALSE
  ),
  i64 = list(
    r_value = "rducks_bigint scalar", sql_null = "NULL", copy = "boxed exact Rducks value object",
    notes = "exact signed 64-bit integer string", uses_r_double_for_integer = FALSE,
    uses_r_double_for_float = FALSE, precision_may_be_lost = FALSE
  ),
  u64 = list(
    r_value = "rducks_ubigint scalar", sql_null = "NULL", copy = "boxed exact Rducks value object",
    notes = "exact unsigned 64-bit integer string", uses_r_double_for_integer = FALSE,
    uses_r_double_for_float = FALSE, precision_may_be_lost = FALSE
  ),
  f32 = list(
    r_value = "numeric(1)", sql_null = "NA_real_", copy = "boxed scalar",
    notes = "widened to R double", uses_r_double_for_integer = FALSE,
    uses_r_double_for_float = TRUE, precision_may_be_lost = FALSE
  ),
  f64 = list(
    r_value = "numeric(1)", sql_null = "NA_real_", copy = "boxed scalar",
    notes = "", uses_r_double_for_integer = FALSE, uses_r_double_for_float = FALSE,
    precision_may_be_lost = FALSE
  ),
  varchar = list(
    r_value = "character(1)", sql_null = "NA_character_", copy = "string copied into R",
    notes = "string copied into R", uses_r_double_for_integer = FALSE,
    uses_r_double_for_float = FALSE, precision_may_be_lost = FALSE
  ),
  blob = list(
    r_value = "raw vector", sql_null = "NULL", copy = "bytes copied into R",
    notes = "bytes copied into R", uses_r_double_for_integer = FALSE,
    uses_r_double_for_float = FALSE, precision_may_be_lost = FALSE
  ),
  date = list(
    r_value = "Date scalar", sql_null = "NA_real_ (unclassed)", copy = "boxed scalar",
    notes = "days since 1970-01-01", uses_r_double_for_integer = FALSE,
    uses_r_double_for_float = FALSE, precision_may_be_lost = FALSE
  ),
  time = list(
    r_value = "numeric(1) seconds", sql_null = "NA_real_", copy = "boxed scalar",
    notes = "microseconds converted to seconds", uses_r_double_for_integer = FALSE,
    uses_r_double_for_float = FALSE, precision_may_be_lost = FALSE
  ),
  timestamp = list(
    r_value = "POSIXct scalar", sql_null = "NA_real_ (unclassed)", copy = "boxed scalar",
    notes = "microseconds converted to seconds", uses_r_double_for_integer = FALSE,
    uses_r_double_for_float = FALSE, precision_may_be_lost = FALSE
  )
)

rducks_exotic_scalar_types <- list(
  hugeint = list(duckdb = "HUGEINT", r = "rducks_hugeint"),
  uhugeint = list(duckdb = "UHUGEINT", r = "rducks_uhugeint"),
  uuid = list(duckdb = "UUID", r = "rducks_uuid"),
  interval = list(duckdb = "INTERVAL", r = "rducks_interval"),
  bit = list(duckdb = "BIT", r = "rducks_bits")
)

rducks_all_scalar_type_names <- function() {
  c(names(rducks_scalar_types$table), names(rducks_exotic_scalar_types))
}

rducks_type_normalize_scalar <- function(token, original = token) {
  token <- tolower(trimws(token))
  if (token %in% names(rducks_scalar_types$aliases)) {
    token <- unname(rducks_scalar_types$aliases[[token]])
  }
  if (!token %in% rducks_all_scalar_type_names()) {
    stop("unsupported scalar Rducks type token: ", original, call. = FALSE)
  }
  token
}

rducks_scalar_duckdb_sql <- function(token) {
  token <- rducks_type_normalize_scalar(token)
  if (token %in% names(rducks_scalar_types$table)) {
    return(rducks_scalar_types$table[[token]]$duckdb)
  }
  rducks_exotic_scalar_types[[token]]$duckdb
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
#' Character input is limited to scalar aliases. Composite, DECIMAL, ENUM, and
#' UNION types are represented by constructed `rducks_type` objects rather than
#' quoted type strings.
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

rducks_type_is_composite <- function(x) {
  inherits(x, "rducks_type") && !identical(rducks_type_kind(x), "scalar")
}

rducks_type_info <- function(x) {
  type <- if (inherits(x, "rducks_type")) x else rducks_type_object(x)
  token <- rducks_type_token(type)
  out <- rducks_scalar_types$table[[token]] %||% rducks_exotic_scalar_types[[token]] %||% list()
  out$token <- token
  out$duckdb_sql <- rducks_type_duckdb_sql(type)
  out$kind <- rducks_type_kind(type)
  out$children <- rducks_type_children(type)
  out$child_names <- rducks_type_child_names(type)
  out$size <- rducks_type_size(type)
  out$parameters <- rducks_type_parameters(type)
  out
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
  sym <- rducks_get_native_symbol("RDUCKS_type_object_is")
  if (!is.null(sym)) {
    return(isTRUE(.Call(sym, x)))
  }
  if (!inherits(x, "rducks_type")) {
    return(FALSE)
  }
  ok_scalar <- function(value) is.character(value) && length(value) == 1L && !is.na(value) && nzchar(value)
  ok_scalar(rducks_type_token(x)) &&
    ok_scalar(rducks_type_duckdb_sql(x)) &&
    ok_scalar(rducks_type_kind(x)) &&
    is.list(rducks_type_children(x)) &&
    is.character(rducks_type_child_names(x)) &&
    length(rducks_type_child_names(x)) == length(rducks_type_children(x)) &&
    is.integer(rducks_type_size(x)) && length(rducks_type_size(x)) == 1L &&
    is.list(rducks_type_parameters(x))
}

#' @rdname rducks_type_objects
#' @export
BOOLEAN <- rducks_type_object("BOOLEAN")
#' @rdname rducks_type_objects
#' @export
TINYINT <- rducks_type_object("TINYINT")
#' @rdname rducks_type_objects
#' @export
UTINYINT <- rducks_type_object("UTINYINT")
#' @rdname rducks_type_objects
#' @export
SMALLINT <- rducks_type_object("SMALLINT")
#' @rdname rducks_type_objects
#' @export
USMALLINT <- rducks_type_object("USMALLINT")
#' @rdname rducks_type_objects
#' @export
INTEGER <- rducks_type_object("INTEGER")
#' @rdname rducks_type_objects
#' @export
UINTEGER <- rducks_type_object("UINTEGER")
#' @rdname rducks_type_objects
#' @export
BIGINT <- rducks_type_object("BIGINT")
#' @rdname rducks_type_objects
#' @export
UBIGINT <- rducks_type_object("UBIGINT")
#' @rdname rducks_type_objects
#' @export
FLOAT <- rducks_type_object("FLOAT")
#' @rdname rducks_type_objects
#' @export
DOUBLE <- rducks_type_object("DOUBLE")
#' @rdname rducks_type_objects
#' @export
VARCHAR <- rducks_type_object("VARCHAR")
#' @rdname rducks_type_objects
#' @export
BLOB <- rducks_type_object("BLOB")
#' @rdname rducks_type_objects
#' @export
DATE <- rducks_type_object("DATE")
#' @rdname rducks_type_objects
#' @export
TIME <- rducks_type_object("TIME")
#' @rdname rducks_type_objects
#' @export
TIMESTAMP <- rducks_type_object("TIMESTAMP")
#' @rdname rducks_type_objects
#' @export
HUGEINT <- rducks_type_object("HUGEINT")
#' @rdname rducks_type_objects
#' @export
UHUGEINT <- rducks_type_object("UHUGEINT")
#' @rdname rducks_type_objects
#' @export
UUID <- rducks_type_object("UUID")
#' @rdname rducks_type_objects
#' @export
INTERVAL <- rducks_type_object("INTERVAL")
#' @rdname rducks_type_objects
#' @export
BIT <- rducks_type_object("BIT")

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

rducks_argument_type_kind <- function(token) {
  if (inherits(token, "rducks_type")) {
    return(rducks_type_kind(token))
  }
  rducks_type_kind_from_token(token)
}

rducks_scalar_argument_mapping_row <- function(token) {
  token <- rducks_type_normalize_scalar(token)
  info <- rducks_scalar_types$table[[token]]
  spec <- rducks_scalar_argument_mapping_specs[[token]]
  if (!is.null(info) && !is.null(spec)) {
    return(data.frame(
      rducks_type = token,
      duckdb_sql = info$duckdb,
      argument_kind = "scalar",
      r_type = info$r,
      r_value_passed_to_fun = spec$r_value,
      sql_null_in_callback = spec$sql_null,
      copy_semantics = spec$copy,
      uses_r_double_for_integer = spec$uses_r_double_for_integer,
      uses_r_double_for_float = spec$uses_r_double_for_float,
      precision_may_be_lost = spec$precision_may_be_lost,
      notes = spec$notes,
      stringsAsFactors = FALSE,
      check.names = FALSE
    ))
  }
  info <- rducks_exotic_scalar_types[[token]]
  if (!is.null(info)) {
    return(data.frame(
      rducks_type = token,
      duckdb_sql = info$duckdb,
      argument_kind = "exotic",
      r_type = info$r,
      r_value_passed_to_fun = info$r,
      sql_null_in_callback = "NULL",
      copy_semantics = "boxed exact Rducks value object",
      uses_r_double_for_integer = FALSE,
      uses_r_double_for_float = FALSE,
      precision_may_be_lost = FALSE,
      notes = "exact Rducks value class",
      stringsAsFactors = FALSE,
      check.names = FALSE
    ))
  }
  stop("missing scalar argument type mapping for: ", token, call. = FALSE)
}

rducks_sequence_child_type <- function(token) {
  if (inherits(token, "rducks_type")) {
    if (!rducks_type_kind(token) %in% c("list", "array")) {
      stop("type is not a list or array: ", rducks_type_token(token), call. = FALSE)
    }
    return(rducks_type_token(rducks_type_children(token)[[1L]]))
  }
  type <- rducks_type_object(token)
  rducks_sequence_child_type(type)
}

rducks_map_child_types <- function(token) {
  if (inherits(token, "rducks_type")) {
    if (!identical(rducks_type_kind(token), "map")) {
      stop("type is not a map: ", rducks_type_token(token), call. = FALSE)
    }
    return(vapply(rducks_type_children(token), rducks_type_token, character(1)))
  }
  type <- rducks_type_object(token)
  rducks_map_child_types(type)
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

rducks_row_mapping_supported <- function(type) {
  type <- if (inherits(type, "rducks_type")) type else rducks_type_object(type)
  kind <- rducks_type_kind(type)
  if (identical(kind, "scalar")) {
    return(rducks_type_token(type) %in% rducks_all_scalar_type_names())
  }
  if (kind %in% c("decimal", "enum")) {
    return(TRUE)
  }
  if (kind %in% c("list", "array", "struct", "map", "union")) {
    return(all(vapply(rducks_type_children(type), rducks_row_mapping_supported, logical(1))))
  }
  FALSE
}

rducks_unsupported_duckdb_types <- function(type) {
  type <- if (inherits(type, "rducks_type")) type else rducks_type_object(type)
  if (rducks_row_mapping_supported(type)) {
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
    stop("row-mode argument marshalling is not available for ", paste(unsupported, collapse = ", "), call. = FALSE)
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
      "row-mode argument marshalling is not available for ",
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
    sql_null_in_callback = "NULL",
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
    "r_value_passed_to_fun", "sql_null_in_callback", "copy_semantics",
    "uses_r_double_for_integer", "uses_r_double_for_float", "precision_may_be_lost",
    "notes"
  )
  missing <- setdiff(required, names(mapping))
  if (length(missing)) {
    stop("argument type mapping is missing columns: ", paste(missing, collapse = ", "), call. = FALSE)
  }
  scalar_tokens <- names(rducks_scalar_types$table)
  spec_tokens <- names(rducks_scalar_argument_mapping_specs)
  if (!setequal(scalar_tokens, spec_tokens)) {
    stop("scalar argument type mapping must cover exactly the scalar type table", call. = FALSE)
  }
  scalar_rows <- mapping[mapping$argument_kind == "scalar", , drop = FALSE]
  if (nrow(scalar_rows)) {
    for (i in seq_len(nrow(scalar_rows))) {
      token <- scalar_rows$rducks_type[[i]]
      info <- rducks_scalar_types$table[[token]] %||% rducks_exotic_scalar_types[[token]]
      if (is.null(info)) {
        stop("unknown scalar argument type mapping row: ", token, call. = FALSE)
      }
      if (!identical(scalar_rows$duckdb_sql[[i]], info$duckdb)) {
        stop("DuckDB SQL mapping mismatch for scalar type: ", token, call. = FALSE)
      }
      if (!identical(scalar_rows$r_type[[i]], info$r)) {
        stop("R type mapping mismatch for scalar type: ", token, call. = FALSE)
      }
    }
  }
  invisible(TRUE)
}

#' Describe how Rducks argument values are passed to R callbacks
#'
#' `rducks_argument_type_mapping()` is the package-level source of truth for the
#' R value shape used when DuckDB argument values are marshalled into an R
#' callback. It is used by registration checks and wrapper code generation.
#'
#' With `null_handling = "default"`, top-level SQL `NULL` inputs short-circuit
#' to a SQL `NULL` result and the R callback is not called. The
#' `sql_null_in_callback` column describes the value passed only when
#' `null_handling = "special"`. For composite inputs, top-level `NULL` values
#' are passed as R `NULL`; `NULL` elements in homogeneous scalar lists/arrays
#' are represented as typed `NA` values, while nested composite `NULL` values
#' are represented as R `NULL`.
#'
#' The default table contains all scalar types supported by row-mode native
#' marshalling. `DECIMAL`, `ENUM`, `UNION`, and composite descriptors can be
#' requested explicitly to inspect their recursive R callback shapes.
#'
#' @param x Optional scalar type tokens or constructed `rducks_type` objects.
#'   When `NULL`, all currently implemented row-mode scalar argument mappings
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
      sql_null_in_callback = character(), copy_semantics = character(),
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
