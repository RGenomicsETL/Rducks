rducks_scalar_types <- local({
  table <- list(
    bool = list(c = "bool", duckdb = "BOOLEAN", r = "logical"),
    i8 = list(c = "int8_t", duckdb = "TINYINT", r = "integer"),
    u8 = list(c = "uint8_t", duckdb = "UTINYINT", r = "integer"),
    i16 = list(c = "int16_t", duckdb = "SMALLINT", r = "integer"),
    u16 = list(c = "uint16_t", duckdb = "USMALLINT", r = "integer"),
    i32 = list(c = "int32_t", duckdb = "INTEGER", r = "integer"),
    u32 = list(c = "uint32_t", duckdb = "UINTEGER", r = "numeric"),
    i64 = list(c = "int64_t", duckdb = "BIGINT", r = "numeric"),
    u64 = list(c = "uint64_t", duckdb = "UBIGINT", r = "numeric"),
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
    r_value = "numeric(1)", sql_null = "NA_real_", copy = "boxed scalar",
    notes = "R double; exact only up to 2^53", uses_r_double_for_integer = TRUE,
    uses_r_double_for_float = FALSE, precision_may_be_lost = TRUE
  ),
  u64 = list(
    r_value = "numeric(1)", sql_null = "NA_real_", copy = "boxed scalar",
    notes = "R double; exact only up to 2^53", uses_r_double_for_integer = TRUE,
    uses_r_double_for_float = FALSE, precision_may_be_lost = TRUE
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

#' Normalize an Rducks type token
#'
#' @param x Character scalar type token.
#' @return Canonical type token.
#' @export
rducks_type_normalize <- function(x) {
  if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x)) {
    stop("type token must be a non-empty character scalar", call. = FALSE)
  }
  token <- tolower(trimws(x))
  token <- sub("^duckdb_", "", token)
  if (token %in% names(rducks_scalar_types$aliases)) {
    token <- unname(rducks_scalar_types$aliases[[token]])
  }
  if (rducks_type_is_composite(token)) {
    return(gsub("\\s+", "", token))
  }
  if (!token %in% names(rducks_scalar_types$table)) {
    stop("unsupported Rducks type token: ", x, call. = FALSE)
  }
  token
}

#' Normalize a vector of Rducks type tokens
#'
#' @param x Character vector of type tokens.
#' @return Character vector of canonical type tokens.
#' @export
rducks_types_normalize <- function(x) {
  if (!is.character(x)) {
    stop("types must be a character vector", call. = FALSE)
  }
  vapply(x, rducks_type_normalize, character(1), USE.NAMES = FALSE)
}

rducks_type_is_composite <- function(x) {
  token <- tolower(trimws(x))
  grepl("^(list|struct|map)<", token) || grepl("\\[[0-9]*\\]$", token)
}

rducks_type_info <- function(x) {
  token <- rducks_type_normalize(x)
  info <- rducks_scalar_types$table[[token]]
  info$token <- token
  info
}

rducks_find_top_level <- function(x, chars) {
  depth_angle <- 0L
  depth_square <- 0L
  n <- nchar(x)
  if (!n) return(integer())
  out <- integer()
  for (i in seq_len(n)) {
    ch <- substr(x, i, i)
    if (identical(ch, "<")) depth_angle <- depth_angle + 1L
    else if (identical(ch, ">")) depth_angle <- max(0L, depth_angle - 1L)
    else if (identical(ch, "[")) depth_square <- depth_square + 1L
    else if (identical(ch, "]")) depth_square <- max(0L, depth_square - 1L)
    else if (depth_angle == 0L && depth_square == 0L && ch %in% chars) out <- c(out, i)
  }
  out
}

rducks_split_top_level <- function(x, chars = c(",", ";")) {
  pos <- rducks_find_top_level(x, chars)
  if (!length(pos)) return(x)
  starts <- c(1L, pos + 1L)
  ends <- c(pos - 1L, nchar(x))
  trimws(substring(x, starts, ends))
}

rducks_type_scalar_leaves <- function(token) {
  token <- rducks_type_normalize(token)
  if (token %in% names(rducks_scalar_types$table)) {
    return(token)
  }
  if (grepl("^list<.*>$", token)) {
    inner <- substring(token, 6L, nchar(token) - 1L)
    return(rducks_type_scalar_leaves(inner))
  }
  if (grepl("^map<.*>$", token)) {
    inner <- substring(token, 5L, nchar(token) - 1L)
    parts <- rducks_split_top_level(inner, c(";", ","))
    if (length(parts) != 2L) stop("map type must be map<key;value>", call. = FALSE)
    return(unlist(lapply(parts, rducks_type_scalar_leaves), use.names = FALSE))
  }
  if (grepl("^struct<.*>$", token)) {
    inner <- substring(token, 8L, nchar(token) - 1L)
    fields <- rducks_split_top_level(inner, ";")
    return(unlist(lapply(fields, function(field) {
      pos <- rducks_find_top_level(field, ":")
      if (length(pos) != 1L) stop("struct fields must be name:type", call. = FALSE)
      rducks_type_scalar_leaves(substring(field, pos + 1L))
    }), use.names = FALSE))
  }
  if (grepl("\\[[0-9]*\\]$", token)) {
    open <- regexpr("\\[[0-9]*\\]$", token)[[1L]]
    child <- substring(token, 1L, open - 1L)
    return(rducks_type_scalar_leaves(child))
  }
  stop("unsupported Rducks type token: ", token, call. = FALSE)
}

rducks_duckdb_type_one <- function(token) {
  token <- rducks_type_normalize(token)
  if (token %in% names(rducks_scalar_types$table)) {
    return(rducks_scalar_types$table[[token]]$duckdb)
  }
  if (grepl("^list<.*>$", token)) {
    inner <- substring(token, 6L, nchar(token) - 1L)
    return(paste0(rducks_duckdb_type_one(inner), "[]"))
  }
  if (grepl("^map<.*>$", token)) {
    inner <- substring(token, 5L, nchar(token) - 1L)
    parts <- rducks_split_top_level(inner, c(";", ","))
    if (length(parts) != 2L) stop("map type must be map<key;value>", call. = FALSE)
    return(sprintf("MAP(%s, %s)", rducks_duckdb_type_one(parts[[1L]]), rducks_duckdb_type_one(parts[[2L]])))
  }
  if (grepl("^struct<.*>$", token)) {
    inner <- substring(token, 8L, nchar(token) - 1L)
    fields <- rducks_split_top_level(inner, ";")
    field_sql <- vapply(fields, function(field) {
      pos <- rducks_find_top_level(field, ":")
      if (length(pos) != 1L) stop("struct fields must be name:type", call. = FALSE)
      name <- substring(field, 1L, pos - 1L)
      type <- substring(field, pos + 1L)
      sprintf("%s %s", name, rducks_duckdb_type_one(type))
    }, character(1), USE.NAMES = FALSE)
    return(sprintf("STRUCT(%s)", paste(field_sql, collapse = ", ")))
  }
  if (grepl("\\[[0-9]*\\]$", token)) {
    open <- regexpr("\\[[0-9]*\\]$", token)[[1L]]
    child <- substring(token, 1L, open - 1L)
    len <- substring(token, open + 1L, nchar(token) - 1L)
    if (!nzchar(len)) return(paste0(rducks_duckdb_type_one(child), "[]"))
    return(sprintf("%s[%s]", rducks_duckdb_type_one(child), len))
  }
  stop("unsupported Rducks type token: ", token, call. = FALSE)
}

rducks_argument_type_kind <- function(token) {
  token <- rducks_type_normalize(token)
  if (token %in% names(rducks_scalar_types$table)) {
    return("scalar")
  }
  if (grepl("^list<.*>$", token)) {
    return("list")
  }
  if (grepl("^map<.*>$", token)) {
    return("map")
  }
  if (grepl("^struct<.*>$", token)) {
    return("struct")
  }
  if (grepl("\\[[0-9]*\\]$", token)) {
    open <- regexpr("\\[[0-9]*\\]$", token)[[1L]]
    len <- substring(token, open + 1L, nchar(token) - 1L)
    return(if (nzchar(len)) "array" else "list")
  }
  stop("unsupported Rducks type token: ", token, call. = FALSE)
}

rducks_scalar_argument_mapping_row <- function(token) {
  info <- rducks_scalar_types$table[[token]]
  spec <- rducks_scalar_argument_mapping_specs[[token]]
  if (is.null(info) || is.null(spec)) {
    stop("missing scalar argument type mapping for: ", token, call. = FALSE)
  }
  data.frame(
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
  )
}

rducks_composite_argument_mapping_row <- function(token) {
  token <- rducks_type_normalize(token)
  kind <- rducks_argument_type_kind(token)
  duckdb_sql <- rducks_duckdb_type_one(token)
  r_value <- switch(kind,
    list = "list of element values",
    array = {
      open <- regexpr("\\[[0-9]+\\]$", token)[[1L]]
      len <- substring(token, open + 1L, nchar(token) - 1L)
      paste0("list of length ", len)
    },
    struct = "named list of fields",
    map = "list(keys = ..., values = ...)",
    stop("unsupported composite argument kind: ", kind, call. = FALSE)
  )
  notes <- switch(kind,
    list = if (grepl("\\[]$", token)) "same as list<type>" else "recursive element mapping",
    array = "fixed-size array",
    struct = "recursive field mapping",
    map = "keys and values are recursive lists",
    ""
  )
  leaf_rows <- do.call(rbind, lapply(unique(rducks_type_scalar_leaves(token)), rducks_scalar_argument_mapping_row))
  data.frame(
    rducks_type = token,
    duckdb_sql = duckdb_sql,
    argument_kind = kind,
    r_type = "list",
    r_value_passed_to_fun = r_value,
    sql_null_in_callback = "NULL",
    copy_semantics = "recursive R allocation",
    uses_r_double_for_integer = any(leaf_rows$uses_r_double_for_integer),
    uses_r_double_for_float = any(leaf_rows$uses_r_double_for_float),
    precision_may_be_lost = any(leaf_rows$precision_may_be_lost),
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
      info <- rducks_scalar_types$table[[token]]
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
#' `null_handling = "special"`. Nested SQL `NULL` values inside composite
#' inputs are represented as R `NULL`.
#'
#' @param x Optional character vector of Rducks type tokens. When `NULL`, all
#'   scalar argument mappings are returned. Composite tokens such as
#'   `list<i32>`, `i32[]`, `i32[3]`, `struct<a:i32;b:varchar>`, and
#'   `map<varchar;i32>` can be supplied explicitly.
#' @return A data frame with one row per requested type token.
#' @export
rducks_argument_type_mapping <- function(x = NULL) {
  tokens <- if (is.null(x)) names(rducks_scalar_types$table) else rducks_types_normalize(x)
  rows <- lapply(tokens, function(token) {
    if (token %in% names(rducks_scalar_types$table)) {
      rducks_scalar_argument_mapping_row(token)
    } else {
      rducks_composite_argument_mapping_row(token)
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
  tokens <- rducks_types_normalize(x)
  vapply(tokens, rducks_duckdb_type_one, character(1), USE.NAMES = FALSE)
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
