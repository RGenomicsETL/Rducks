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

rducks_type_info <- function(x) {
  token <- rducks_type_normalize(x)
  info <- rducks_scalar_types$table[[token]]
  info$token <- token
  info
}

#' Convert Rducks type tokens to DuckDB SQL types
#'
#' @param x Character vector of type tokens.
#' @return Character vector of DuckDB SQL type names.
#' @export
rducks_duckdb_types <- function(x) {
  tokens <- rducks_types_normalize(x)
  vapply(tokens, function(token) rducks_scalar_types$table[[token]]$duckdb,
    character(1), USE.NAMES = FALSE
  )
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
