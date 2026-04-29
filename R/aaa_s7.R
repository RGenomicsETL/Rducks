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

rducks_get_native_symbol <- function(name) {
  get0(name, envir = environment(rducks_get_native_symbol), inherits = FALSE)
}

rducks_type_class_for_kind <- function(kind) {
  switch(kind,
    scalar = rducks_scalar_type_class,
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

rducks_type_class_vector_for_kind <- function(kind) {
  c(
    switch(kind,
      scalar = "rducks_scalar_type",
      list = "rducks_list_type",
      array = "rducks_array_type",
      struct = "rducks_struct_type",
      map = "rducks_map_type",
      decimal = "rducks_decimal_type",
      enum = "rducks_enum_type",
      union = "rducks_union_type",
      stop("unknown Rducks type kind: ", kind, call. = FALSE)
    ),
    "rducks_type", "list", "S7_object"
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
  class <- rducks_type_class_for_kind(kind)
  sym <- rducks_get_native_symbol("RDUCKS_type_object_new")
  if (!is.null(sym)) {
    return(.Call(
      sym, token, duckdb_sql, kind, children, child_names, size, parameters,
      class, rducks_type_class_vector_for_kind(kind)
    ))
  }
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
rducks_type_token <- function(x, ...) UseMethod("rducks_type_token")

#' @export
rducks_type_token.default <- function(x, ...) rducks_type_method_error(x, "rducks_type_token()")

#' @export
rducks_type_token.rducks_type <- function(x, ...) rducks_type_prop(x, "token")

#' @rdname rducks_type_token
#' @export
rducks_type_sql <- function(x, ...) UseMethod("rducks_type_sql")

#' @export
rducks_type_sql.default <- function(x, ...) rducks_type_method_error(x, "rducks_type_sql()")

#' @export
rducks_type_sql.rducks_type <- function(x, ...) rducks_type_prop(x, "duckdb_sql")

rducks_type_duckdb_sql <- function(x) rducks_type_sql(x)

#' @rdname rducks_type_token
#' @export
rducks_type_kind <- function(x, ...) UseMethod("rducks_type_kind")

#' @export
rducks_type_kind.default <- function(x, ...) rducks_type_method_error(x, "rducks_type_kind()")

#' @export
rducks_type_kind.rducks_type <- function(x, ...) rducks_type_prop(x, "kind")

#' @rdname rducks_type_token
#' @export
rducks_type_children <- function(x, ...) UseMethod("rducks_type_children")

#' @export
rducks_type_children.default <- function(x, ...) rducks_type_method_error(x, "rducks_type_children()")

#' @export
rducks_type_children.rducks_type <- function(x, ...) rducks_type_prop(x, "children")

#' @rdname rducks_type_token
#' @export
rducks_type_child_names <- function(x, ...) UseMethod("rducks_type_child_names")

#' @export
rducks_type_child_names.default <- function(x, ...) rducks_type_method_error(x, "rducks_type_child_names()")

#' @export
rducks_type_child_names.rducks_type <- function(x, ...) rducks_type_prop(x, "child_names")

#' @rdname rducks_type_token
#' @export
rducks_type_size <- function(x, ...) UseMethod("rducks_type_size")

#' @export
rducks_type_size.default <- function(x, ...) rducks_type_method_error(x, "rducks_type_size()")

#' @export
rducks_type_size.rducks_type <- function(x, ...) rducks_type_prop(x, "size")

#' @rdname rducks_type_token
#' @export
rducks_type_parameters <- function(x, ...) UseMethod("rducks_type_parameters")

#' @export
rducks_type_parameters.default <- function(x, ...) rducks_type_method_error(x, "rducks_type_parameters()")

#' @export
rducks_type_parameters.rducks_type <- function(x, ...) rducks_type_prop(x, "parameters")
