rducks_value_semantics_scalar <- function(type) {
  token <- rducks_type_token(type)
  input_mapping <- rducks_argument_type_mapping(type)

  base <- list(
    rducks_type = token,
    duckdb_sql = rducks_type_duckdb_sql(type),
    kind = rducks_type_kind(type),
    r_type = input_mapping$r_type[[1L]],
    sql_null_input_default = "short-circuit to SQL NULL result; R function is not called",
    sql_null_input_special = input_mapping$sql_null_in_function[[1L]],
    sql_nan_inf_input = "not representable for this DuckDB type",
    r_null_return = "SQL NULL",
    r_na_return = "SQL NULL when represented by the declared R type",
    r_nan_return = "not applicable",
    r_inf_return = "not applicable",
    binary_ops = "no Rducks-specific binary ops",
    error_semantics = "values incompatible with the declared type error during checking or marshalling",
    notes = input_mapping$notes[[1L]]
  )

  integer_error <- "NaN, Inf, fractional, and out-of-range return values error"
  integer_class_error <- "non-integer strings, numeric NaN/Inf, and out-of-range values error"

  spec <- switch(token,
    bool = list(
      r_na_return = "NA_logical_ -> SQL NULL",
      error_semantics = "non-logical values are incompatible with BOOLEAN"
    ),
    i8 = list(r_na_return = "NA_integer_ -> SQL NULL", r_nan_return = "error", r_inf_return = "error", error_semantics = integer_error),
    u8 = list(r_na_return = "NA_integer_ -> SQL NULL", r_nan_return = "error", r_inf_return = "error", error_semantics = integer_error),
    i16 = list(r_na_return = "NA_integer_ -> SQL NULL", r_nan_return = "error", r_inf_return = "error", error_semantics = integer_error),
    u16 = list(r_na_return = "NA_integer_ -> SQL NULL", r_nan_return = "error", r_inf_return = "error", error_semantics = integer_error),
    i32 = list(r_na_return = "NA_integer_ -> SQL NULL", r_nan_return = "error", r_inf_return = "error", error_semantics = integer_error),
    u32 = list(r_na_return = "NA_real_ -> SQL NULL", r_nan_return = "error", r_inf_return = "error", error_semantics = integer_error),
    i64 = list(
      r_na_return = "rducks_bigint(NA) -> SQL NULL",
      r_nan_return = "error",
      r_inf_return = "error",
      binary_ops = "rducks_bigint +, -, comparisons; NA propagates; range errors remain errors",
      error_semantics = integer_class_error
    ),
    u64 = list(
      r_na_return = "rducks_ubigint(NA) -> SQL NULL",
      r_nan_return = "error",
      r_inf_return = "error",
      binary_ops = "rducks_ubigint +, -, comparisons; NA propagates; unsigned underflow/range errors remain errors",
      error_semantics = integer_class_error
    ),
    f32 = list(
      sql_nan_inf_input = "DuckDB NaN/Inf pass through as R numeric values",
      r_na_return = "NA_real_ -> SQL NULL",
      r_nan_return = "preserved as DuckDB NaN",
      r_inf_return = "preserved as DuckDB +/-Inf",
      binary_ops = "ordinary R numeric semantics in the R function",
      error_semantics = "NA is NULL; NaN and Inf are valid FLOAT values"
    ),
    f64 = list(
      sql_nan_inf_input = "DuckDB NaN/Inf pass through as R numeric values",
      r_na_return = "NA_real_ -> SQL NULL",
      r_nan_return = "preserved as DuckDB NaN",
      r_inf_return = "preserved as DuckDB +/-Inf",
      binary_ops = "ordinary R numeric semantics in the R function",
      error_semantics = "NA is NULL; NaN and Inf are valid DOUBLE values"
    ),
    varchar = list(
      r_na_return = "NA_character_ -> SQL NULL",
      error_semantics = "values that cannot be converted to character error during checking or marshalling"
    ),
    blob = list(
      r_na_return = "raw vectors have no NA payload; use R NULL for SQL NULL",
      error_semantics = "non-raw return values error"
    ),
    date = list(
      r_na_return = "Date NA / NA_real_ -> SQL NULL",
      r_nan_return = "error",
      r_inf_return = "error",
      error_semantics = "NaN, Inf, fractional days, and out-of-range days error"
    ),
    time = list(
      r_na_return = "NA_real_ -> SQL NULL",
      r_nan_return = "error",
      r_inf_return = "error",
      error_semantics = "NaN, Inf, values outside [0, 86400), and values rounding to 24:00:00 error"
    ),
    timestamp = list(
      r_na_return = "POSIXct NA / NA_real_ -> SQL NULL",
      r_nan_return = "error",
      r_inf_return = "error",
      error_semantics = "NaN, Inf, and out-of-range timestamp seconds error"
    ),
    hugeint = list(
      r_na_return = "rducks_hugeint(NA) -> SQL NULL",
      r_nan_return = "error",
      r_inf_return = "error",
      binary_ops = "rducks_hugeint +, -, comparisons; NA propagates; range errors remain errors",
      error_semantics = integer_class_error
    ),
    uhugeint = list(
      r_na_return = "rducks_uhugeint(NA) -> SQL NULL",
      r_nan_return = "error",
      r_inf_return = "error",
      binary_ops = "rducks_uhugeint +, -, comparisons; NA propagates; unsigned underflow/range errors remain errors",
      error_semantics = integer_class_error
    ),
    uuid = list(
      r_na_return = "rducks_uuid(NA) -> SQL NULL",
      r_nan_return = "error",
      r_inf_return = "error",
      error_semantics = "NA UUID values are NULL; malformed UUID text errors"
    ),
    interval = list(
      r_na_return = "any NA component in rducks_interval() -> SQL NULL",
      r_nan_return = "error",
      r_inf_return = "error",
      binary_ops = "rducks_interval + and -; NA components propagate; component overflow remains an error",
      error_semantics = "NaN/Inf components and months/days/micros outside DuckDB ranges error"
    ),
    bit = list(
      r_na_return = "no NA bit payload; use R NULL for SQL NULL",
      r_nan_return = "error",
      r_inf_return = "error",
      binary_ops = "rducks_bits &, |, !, rducks_bits_xor(); NA bits are rejected",
      error_semantics = "BIT inputs must contain only 0/1 or TRUE/FALSE; NA bits error"
    ),
    list()
  )

  utils::modifyList(base, spec)
}

rducks_value_semantics_constructed <- function(type) {
  kind <- rducks_type_kind(type)
  input_mapping <- rducks_argument_type_mapping(type)
  base <- list(
    rducks_type = rducks_type_token(type),
    duckdb_sql = rducks_type_duckdb_sql(type),
    kind = kind,
    r_type = input_mapping$r_type[[1L]],
    sql_null_input_default = "short-circuit to SQL NULL result; R function is not called",
    sql_null_input_special = input_mapping$sql_null_in_function[[1L]],
    sql_nan_inf_input = "recursive: only FLOAT/DOUBLE children can carry NaN/Inf",
    r_null_return = "SQL NULL for the top-level value; nested NULLs map recursively",
    r_na_return = "recursive child semantics",
    r_nan_return = "recursive child semantics",
    r_inf_return = "recursive child semantics",
    binary_ops = "no descriptor-level Rducks binary ops; child value classes keep their own ops",
    error_semantics = "shape, length, field, tag, and child type mismatches error during checking or marshalling",
    notes = input_mapping$notes[[1L]]
  )

  spec <- switch(kind,
    decimal = list(
      sql_nan_inf_input = "not representable for DuckDB DECIMAL",
      r_na_return = "rducks_decimal(NA, width, scale) -> SQL NULL",
      r_nan_return = "error",
      r_inf_return = "error",
      binary_ops = "rducks_decimal +, -, comparisons; NA propagates; matching scales are required",
      error_semantics = "NaN/Inf numeric inputs, scale/width mismatch, and DECIMAL arithmetic overflow error"
    ),
    enum = list(
      sql_nan_inf_input = "not representable for DuckDB ENUM",
      r_na_return = "rducks_enum(NA, levels) -> SQL NULL",
      r_nan_return = "not applicable",
      r_inf_return = "not applicable",
      binary_ops = "no Rducks-specific ENUM binary ops",
      error_semantics = "values outside the declared enum levels error"
    ),
    union = list(
      sql_nan_inf_input = "recursive: only FLOAT/DOUBLE union members can carry NaN/Inf",
      r_na_return = "no missing tag; NA in the selected child follows that child semantics",
      r_nan_return = "recursive selected-child semantics",
      r_inf_return = "recursive selected-child semantics",
      binary_ops = "no Rducks-specific UNION binary ops",
      error_semantics = "missing, empty, or unknown tags and selected-child mismatches error"
    ),
    list = list(
      r_na_return = "scalar child NA values become SQL NULL elements; nested child values recurse",
      error_semantics = "non-list values for nested children, incompatible scalar vectors, and malformed elements error"
    ),
    array = list(
      r_na_return = "scalar child NA values become SQL NULL elements; nested child values recurse",
      error_semantics = "wrong array length, non-list values for nested children, incompatible scalar vectors, and malformed elements error"
    ),
    struct = list(
      r_na_return = "field values recurse; scalar field NA values become SQL NULL fields",
      error_semantics = "missing fields and field type mismatches error"
    ),
    map = list(
      r_na_return = "values recurse; scalar NA values become SQL NULL value entries; NULL/NA keys error",
      error_semantics = "keys/values length mismatch, NULL/NA keys, and child type mismatches error"
    ),
    list()
  )

  utils::modifyList(base, spec)
}

rducks_value_semantics_row <- function(type) {
  type <- if (inherits(type, "rducks_type")) type else rducks_type_object(type)
  if (identical(rducks_type_kind(type), "scalar")) {
    rducks_value_semantics_scalar(type)
  } else {
    rducks_value_semantics_constructed(type)
  }
}

rducks_value_semantics_empty <- function() {
  data.frame(
    rducks_type = character(), duckdb_sql = character(), kind = character(), r_type = character(),
    sql_null_input_default = character(), sql_null_input_special = character(), sql_nan_inf_input = character(),
    r_null_return = character(), r_na_return = character(), r_nan_return = character(), r_inf_return = character(),
    binary_ops = character(), error_semantics = character(), notes = character(),
    stringsAsFactors = FALSE, check.names = FALSE
  )
}

#' Describe Rducks NULL, NA, NaN, and Inf semantics
#'
#' `rducks_value_semantics()` is the package-level schema for scalar-mode
#' missing and non-finite value handling. It is intended to be rendered directly in
#' README and pkgdown documentation, and to keep the documented NULL/NA/NaN/Inf
#' contract close to the type descriptors used by the marshaller.
#'
#' With `null_handling = "default"`, top-level SQL `NULL` inputs short-circuit
#' to SQL `NULL` and the R function is not called. The
#' `sql_null_input_special` column describes what the R function receives with
#' `null_handling = "special"`.
#'
#' Return semantics are stated from R back to DuckDB. In scalar mode, top-level
#' `NULL` returns map to SQL `NULL`; type-specific R `NA` values also map to SQL
#' `NULL` where a missing representation exists. `NaN` and `Inf` are values only
#' for `FLOAT` and `DOUBLE`; integer, date, time, timestamp, exact, and exotic
#' value classes reject non-finite values.
#'
#' @param x Optional scalar type tokens or constructed `rducks_type` objects.
#'   When `NULL`, all currently implemented scalar-mode scalar type semantics are
#'   returned. Constructed descriptors such as `DECIMAL(10, 2)`,
#'   `ENUM(c("a", "b"))`, `UNION(i = INTEGER, s = VARCHAR)`, `INTEGER[]`,
#'   `INTEGER[3]`, `STRUCT(a = INTEGER)`, and `MAP(VARCHAR, INTEGER)` can be
#'   requested explicitly.
#' @return A data frame with one row per requested type descriptor and columns
#'   describing SQL NULL input handling, R missing/non-finite return handling,
#'   Rducks value-class binary operation behavior, and error semantics.
#' @export
rducks_value_semantics <- function(x = NULL) {
  items <- if (is.null(x)) {
    as.list(rducks_all_scalar_type_names())
  } else if (inherits(x, "rducks_type")) {
    list(x)
  } else {
    rducks_as_type_list(x)
  }
  if (!length(items)) {
    return(rducks_value_semantics_empty())
  }
  rows <- lapply(items, function(item) {
    row <- rducks_value_semantics_row(item)
    as.data.frame(row, stringsAsFactors = FALSE, check.names = FALSE)
  })
  out <- do.call(rbind, rows)
  row.names(out) <- NULL
  out
}
