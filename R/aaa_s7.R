rducks_validate_type_s7 <- function(self) {
  errors <- character()
  token <- S7::prop(self, "token")
  duckdb_sql <- S7::prop(self, "duckdb_sql")
  kind <- S7::prop(self, "kind")
  children <- S7::prop(self, "children")
  child_names <- S7::prop(self, "child_names")
  size <- S7::prop(self, "size")
  parameters <- S7::prop(self, "parameters")

  if (!is.character(token) || length(token) != 1L || is.na(token) || !nzchar(token)) {
    errors <- c(errors, "@token must be a non-empty character scalar")
  }
  if (!is.character(duckdb_sql) || length(duckdb_sql) != 1L || is.na(duckdb_sql) || !nzchar(duckdb_sql)) {
    errors <- c(errors, "@duckdb_sql must be a non-empty character scalar")
  }
  valid_kinds <- c("scalar", "decimal", "enum", "list", "array", "struct", "map", "union")
  if (!is.character(kind) || length(kind) != 1L || is.na(kind) || !kind %in% valid_kinds) {
    errors <- c(errors, "@kind must be one of scalar, decimal, enum, list, array, struct, map, or union")
  }
  if (!is.list(children)) {
    errors <- c(errors, "@children must be a list")
    children <- list()
  }
  if (!is.character(child_names) || length(child_names) != length(children)) {
    errors <- c(errors, "@child_names must be a character vector matching @children")
  }
  if (!is.integer(size) || length(size) != 1L) {
    errors <- c(errors, "@size must be an integer scalar")
    size <- NA_integer_
  }
  if (!is.list(parameters)) {
    errors <- c(errors, "@parameters must be a list")
    parameters <- list()
  }
  if (length(children) && !all(vapply(children, inherits, logical(1), what = "rducks_type"))) {
    errors <- c(errors, "@children must contain only rducks_type objects")
  }

  if (is.character(kind) && length(kind) == 1L && !is.na(kind)) {
    if (identical(kind, "scalar") && length(children) != 0L) {
      errors <- c(errors, "scalar types must not have children")
    } else if (identical(kind, "list") && (length(children) != 1L || !identical(child_names, "child") || !is.na(size))) {
      errors <- c(errors, "list types must have one child named child and no fixed size")
    } else if (identical(kind, "array") && (length(children) != 1L || !identical(child_names, "child") || is.na(size) || size <= 0L)) {
      errors <- c(errors, "array types must have one child named child and a positive fixed size")
    } else if (identical(kind, "struct") && (length(children) == 0L || any(!nzchar(child_names)) || !is.na(size))) {
      errors <- c(errors, "struct types must have one or more named field children and no fixed size")
    } else if (identical(kind, "map") && (length(children) != 2L || !identical(child_names, c("key", "value")) || !is.na(size))) {
      errors <- c(errors, "map types must have key and value children and no fixed size")
    } else if (identical(kind, "union") && (length(children) == 0L || any(!nzchar(child_names)) || !is.na(size))) {
      errors <- c(errors, "union types must have one or more named member children and no fixed size")
    } else if (identical(kind, "enum")) {
      levels <- parameters$levels
      if (length(children) != 0L || !is.na(size) || !is.character(levels) || !length(levels) || anyNA(levels) || any(!nzchar(levels)) || anyDuplicated(levels)) {
        errors <- c(errors, "enum types must have unique non-empty character levels and no children")
      }
    } else if (identical(kind, "decimal")) {
      width <- parameters$width
      scale <- parameters$scale
      if (length(children) != 0L || !is.na(size) || !is.integer(width) || length(width) != 1L || is.na(width) || width < 1L || width > 38L ||
          !is.integer(scale) || length(scale) != 1L || is.na(scale) || scale < 0L || scale > width) {
        errors <- c(errors, "decimal types must have integer width 1..38, integer scale 0..width, and no children")
      }
    }
  }

  if (length(errors)) errors else NULL
}

rducks_type_class <- S7::new_class(
  "rducks_type",
  package = NULL,
  parent = S7::class_list,
  properties = list(
    token = S7::class_character,
    duckdb_sql = S7::class_character,
    kind = S7::class_character,
    children = S7::class_list,
    child_names = S7::class_character,
    size = S7::class_integer,
    parameters = S7::class_list
  ),
  validator = rducks_validate_type_s7
)

rducks_scalar_type_class <- S7::new_class("rducks_scalar_type", package = NULL, parent = rducks_type_class)
rducks_list_type_class <- S7::new_class("rducks_list_type", package = NULL, parent = rducks_type_class)
rducks_array_type_class <- S7::new_class("rducks_array_type", package = NULL, parent = rducks_type_class)
rducks_struct_type_class <- S7::new_class("rducks_struct_type", package = NULL, parent = rducks_type_class)
rducks_map_type_class <- S7::new_class("rducks_map_type", package = NULL, parent = rducks_type_class)
rducks_decimal_type_class <- S7::new_class("rducks_decimal_type", package = NULL, parent = rducks_type_class)
rducks_enum_type_class <- S7::new_class("rducks_enum_type", package = NULL, parent = rducks_type_class)
rducks_union_type_class <- S7::new_class("rducks_union_type", package = NULL, parent = rducks_type_class)

rducks_logical_scalar_type_class <- S7::new_class("rducks_logical_scalar_type", package = NULL, parent = rducks_scalar_type_class)
rducks_r_integer_scalar_type_class <- S7::new_class("rducks_r_integer_scalar_type", package = NULL, parent = rducks_scalar_type_class)
rducks_r_numeric_scalar_type_class <- S7::new_class("rducks_r_numeric_scalar_type", package = NULL, parent = rducks_scalar_type_class)
rducks_exact_integer_scalar_type_class <- S7::new_class("rducks_exact_integer_scalar_type", package = NULL, parent = rducks_scalar_type_class)
rducks_floating_scalar_type_class <- S7::new_class("rducks_floating_scalar_type", package = NULL, parent = rducks_r_numeric_scalar_type_class)
rducks_character_scalar_type_class <- S7::new_class("rducks_character_scalar_type", package = NULL, parent = rducks_scalar_type_class)
rducks_binary_scalar_type_class <- S7::new_class("rducks_binary_scalar_type", package = NULL, parent = rducks_scalar_type_class)
rducks_temporal_scalar_type_class <- S7::new_class("rducks_temporal_scalar_type", package = NULL, parent = rducks_scalar_type_class)
rducks_uuid_scalar_type_class <- S7::new_class("rducks_uuid_scalar_type", package = NULL, parent = rducks_scalar_type_class)
rducks_interval_scalar_type_class <- S7::new_class("rducks_interval_scalar_type", package = NULL, parent = rducks_scalar_type_class)

rducks_bool_type_class <- S7::new_class("rducks_bool_type", package = NULL, parent = rducks_logical_scalar_type_class)
rducks_i8_type_class <- S7::new_class("rducks_i8_type", package = NULL, parent = rducks_r_integer_scalar_type_class)
rducks_u8_type_class <- S7::new_class("rducks_u8_type", package = NULL, parent = rducks_r_integer_scalar_type_class)
rducks_i16_type_class <- S7::new_class("rducks_i16_type", package = NULL, parent = rducks_r_integer_scalar_type_class)
rducks_u16_type_class <- S7::new_class("rducks_u16_type", package = NULL, parent = rducks_r_integer_scalar_type_class)
rducks_i32_type_class <- S7::new_class("rducks_i32_type", package = NULL, parent = rducks_r_integer_scalar_type_class)
rducks_u32_type_class <- S7::new_class("rducks_u32_type", package = NULL, parent = rducks_r_numeric_scalar_type_class)
rducks_i64_type_class <- S7::new_class("rducks_i64_type", package = NULL, parent = rducks_exact_integer_scalar_type_class)
rducks_u64_type_class <- S7::new_class("rducks_u64_type", package = NULL, parent = rducks_exact_integer_scalar_type_class)
rducks_f32_type_class <- S7::new_class("rducks_f32_type", package = NULL, parent = rducks_floating_scalar_type_class)
rducks_f64_type_class <- S7::new_class("rducks_f64_type", package = NULL, parent = rducks_floating_scalar_type_class)
rducks_varchar_type_class <- S7::new_class("rducks_varchar_type", package = NULL, parent = rducks_character_scalar_type_class)
rducks_blob_type_class <- S7::new_class("rducks_blob_type", package = NULL, parent = rducks_binary_scalar_type_class)
rducks_date_type_class <- S7::new_class("rducks_date_type", package = NULL, parent = rducks_temporal_scalar_type_class)
rducks_time_type_class <- S7::new_class("rducks_time_type", package = NULL, parent = rducks_temporal_scalar_type_class)
rducks_timestamp_type_class <- S7::new_class("rducks_timestamp_type", package = NULL, parent = rducks_temporal_scalar_type_class)
rducks_hugeint_type_class <- S7::new_class("rducks_hugeint_type", package = NULL, parent = rducks_exact_integer_scalar_type_class)
rducks_uhugeint_type_class <- S7::new_class("rducks_uhugeint_type", package = NULL, parent = rducks_exact_integer_scalar_type_class)
rducks_uuid_type_class <- S7::new_class("rducks_uuid_type", package = NULL, parent = rducks_uuid_scalar_type_class)
rducks_interval_type_class <- S7::new_class("rducks_interval_type", package = NULL, parent = rducks_interval_scalar_type_class)
rducks_bit_type_class <- S7::new_class("rducks_bit_type", package = NULL, parent = rducks_binary_scalar_type_class)

rducks_validate_type_list_s7 <- function(self) {
  if (!all(vapply(unclass(self), inherits, logical(1), what = "rducks_type"))) {
    "all elements must be rducks_type objects"
  }
}

rducks_type_list_class <- S7::new_class(
  "rducks_type_list",
  package = NULL,
  parent = S7::class_list,
  validator = rducks_validate_type_list_s7
)

rducks_scalar_type_class_for_token <- function(token) {
  switch(rducks_type_normalize_scalar(token),
    bool = rducks_bool_type_class,
    i8 = rducks_i8_type_class,
    u8 = rducks_u8_type_class,
    i16 = rducks_i16_type_class,
    u16 = rducks_u16_type_class,
    i32 = rducks_i32_type_class,
    u32 = rducks_u32_type_class,
    i64 = rducks_i64_type_class,
    u64 = rducks_u64_type_class,
    f32 = rducks_f32_type_class,
    f64 = rducks_f64_type_class,
    varchar = rducks_varchar_type_class,
    blob = rducks_blob_type_class,
    date = rducks_date_type_class,
    time = rducks_time_type_class,
    timestamp = rducks_timestamp_type_class,
    hugeint = rducks_hugeint_type_class,
    uhugeint = rducks_uhugeint_type_class,
    uuid = rducks_uuid_type_class,
    interval = rducks_interval_type_class,
    bit = rducks_bit_type_class,
    stop("unknown scalar Rducks type token: ", token, call. = FALSE)
  )
}

rducks_type_class_for_kind <- function(kind, token = NULL) {
  switch(kind,
    scalar = rducks_scalar_type_class_for_token(token),
    list = rducks_list_type_class,
    array = rducks_array_type_class,
    struct = rducks_struct_type_class,
    map = rducks_map_type_class,
    decimal = rducks_decimal_type_class,
    enum = rducks_enum_type_class,
    union = rducks_union_type_class,
    stop("unknown Rducks type kind: ", kind, call. = FALSE)
  )
}

rducks_type_construct_s7 <- function(token, duckdb_sql, kind, children, child_names, size, parameters = list()) {
  data <- list(
    token = token,
    duckdb_sql = duckdb_sql,
    kind = kind,
    children = children,
    child_names = child_names,
    size = size,
    parameters = parameters
  )
  class <- rducks_type_class_for_kind(kind, token)
  class(data, token = token, duckdb_sql = duckdb_sql, kind = kind,
        children = children, child_names = child_names, size = size, parameters = parameters)
}

rducks_type_prop <- function(x, name) {
  value <- NULL
  if (is.list(x)) {
    value <- x[[name]]
  }
  if (!is.null(value)) {
    return(value)
  }
  S7::prop(x, name)
}

rducks_type_method_error <- function(x, method) {
  stop(method, " requires a rducks_type object, not: ", paste(class(x), collapse = ", "), call. = FALSE)
}

#' Rducks type descriptor helpers
#'
#' These generic helpers expose the formal DuckDB type descriptor carried by
#' objects such as `INTEGER`, `INTEGER[]`, `STRUCT(...)`, `DECIMAL(...)`,
#' `ENUM(...)`, and `UNION(...)`.
#'
#' @param x A `rducks_type` object.
#' @param ... Reserved for methods.
#' @return `rducks_type_token()` returns the internal wire token;
#'   `rducks_type_sql()` returns the DuckDB SQL spelling;
#'   `rducks_type_kind()` returns the descriptor kind; child and parameter
#'   helpers return descriptor metadata.
#' @export
rducks_type_token <- S7::new_generic(
  "rducks_type_token",
  "x",
  function(x, ...) S7::S7_dispatch()
)

S7::method(rducks_type_token, S7::class_any) <- function(x, ...) {
  rducks_type_method_error(x, "rducks_type_token()")
}

S7::method(rducks_type_token, rducks_type_class) <- function(x, ...) {
  rducks_type_prop(x, "token")
}

#' @rdname rducks_type_token
#' @export
rducks_type_sql <- S7::new_generic(
  "rducks_type_sql",
  "x",
  function(x, ...) S7::S7_dispatch()
)

S7::method(rducks_type_sql, S7::class_any) <- function(x, ...) {
  rducks_type_method_error(x, "rducks_type_sql()")
}

S7::method(rducks_type_sql, rducks_type_class) <- function(x, ...) {
  rducks_type_prop(x, "duckdb_sql")
}

rducks_type_duckdb_sql <- function(x) rducks_type_sql(x)

#' @rdname rducks_type_token
#' @export
rducks_type_kind <- S7::new_generic(
  "rducks_type_kind",
  "x",
  function(x, ...) S7::S7_dispatch()
)

S7::method(rducks_type_kind, S7::class_any) <- function(x, ...) {
  rducks_type_method_error(x, "rducks_type_kind()")
}

S7::method(rducks_type_kind, rducks_type_class) <- function(x, ...) {
  rducks_type_prop(x, "kind")
}

#' @rdname rducks_type_token
#' @export
rducks_type_children <- S7::new_generic(
  "rducks_type_children",
  "x",
  function(x, ...) S7::S7_dispatch()
)

S7::method(rducks_type_children, S7::class_any) <- function(x, ...) {
  rducks_type_method_error(x, "rducks_type_children()")
}

S7::method(rducks_type_children, rducks_type_class) <- function(x, ...) {
  rducks_type_prop(x, "children")
}

#' @rdname rducks_type_token
#' @export
rducks_type_child_names <- S7::new_generic(
  "rducks_type_child_names",
  "x",
  function(x, ...) S7::S7_dispatch()
)

S7::method(rducks_type_child_names, S7::class_any) <- function(x, ...) {
  rducks_type_method_error(x, "rducks_type_child_names()")
}

S7::method(rducks_type_child_names, rducks_type_class) <- function(x, ...) {
  rducks_type_prop(x, "child_names")
}

#' @rdname rducks_type_token
#' @export
rducks_type_size <- S7::new_generic(
  "rducks_type_size",
  "x",
  function(x, ...) S7::S7_dispatch()
)

S7::method(rducks_type_size, S7::class_any) <- function(x, ...) {
  rducks_type_method_error(x, "rducks_type_size()")
}

S7::method(rducks_type_size, rducks_type_class) <- function(x, ...) {
  rducks_type_prop(x, "size")
}

#' @rdname rducks_type_token
#' @export
rducks_type_parameters <- S7::new_generic(
  "rducks_type_parameters",
  "x",
  function(x, ...) S7::S7_dispatch()
)

S7::method(rducks_type_parameters, S7::class_any) <- function(x, ...) {
  rducks_type_method_error(x, "rducks_type_parameters()")
}

S7::method(rducks_type_parameters, rducks_type_class) <- function(x, ...) {
  rducks_type_prop(x, "parameters")
}
