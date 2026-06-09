# Bridge between Rducks types/values and the quack wire model.
#
# The wire side is the pure-C codec (RDUCKS_quack_encode_chunk /
# RDUCKS_quack_decode_chunk over src/quack_core.c). This file maps Rducks S7
# type descriptors to wire type specs and Rducks values (with their exotic
# classes) to wire storage columns, reusing the native chunk IR for the
# value-level conversions. Main thread only.

rducks_quack_ltype_ids <- c(
  bool = 10L, i8 = 11L, i16 = 12L, i32 = 13L, i64 = 14L,
  date = 15L, time = 16L, timestamp_s = 17L, timestamp_ms = 18L,
  timestamp = 19L, timestamp_ns = 20L, decimal = 21L,
  f32 = 22L, f64 = 23L, varchar = 25L, blob = 26L, interval = 27L,
  u8 = 28L, u16 = 29L, u32 = 30L, u64 = 31L,
  timestamp_tz = 32L, time_tz = 34L,
  uhugeint = 49L, hugeint = 50L, uuid = 54L,
  struct = 100L, list = 101L, map = 102L, enum = 104L,
  union = 107L, array = 108L, variant = 109L
)

rducks_quack_spec_node <- function(id, width = 0L, scale = 0L, array_size = 0L,
                                   children = list(), enum_labels = character()) {
  list(
    id = as.integer(id),
    width = as.integer(width),
    scale = as.integer(scale),
    array_size = as.integer(array_size),
    children = children,
    enum_labels = as.character(enum_labels)
  )
}

rducks_quack_kind <- function(type) {
  kinds <- names(rducks_quack_ltype_ids)
  hits <- kinds[vapply(kinds, function(k) {
    rducks_type_inherits(type, paste0("rducks_", k, "_type"))
  }, logical(1))]
  if (!length(hits)) {
    stop("Rducks quack bridge: unsupported type ", rducks_type_token(type), call. = FALSE)
  }
  hits[[1]]
}

rducks_quack_decimal_params <- function(type) {
  sql <- rducks_type_duckdb_sql(type)
  m <- regmatches(sql, regexec("DECIMAL\\((\\d+),\\s*(\\d+)\\)", sql))[[1]]
  if (length(m) != 3L) {
    stop("Rducks quack bridge: cannot read DECIMAL parameters from ", sql, call. = FALSE)
  }
  list(width = as.integer(m[[2]]), scale = as.integer(m[[3]]))
}

rducks_quack_array_size <- function(type) {
  sql <- rducks_type_duckdb_sql(type)
  m <- regmatches(sql, regexec("\\[(\\d+)\\]\\s*$", sql))[[1]]
  if (length(m) != 2L) {
    stop("Rducks quack bridge: cannot read ARRAY size from ", sql, call. = FALSE)
  }
  as.integer(m[[2]])
}

rducks_quack_enum_labels <- function(type) {
  levels <- attr(type, "levels", exact = TRUE)
  if (is.character(levels) && length(levels)) return(levels)
  sql <- rducks_type_duckdb_sql(type)
  m <- regmatches(sql, gregexpr("'((?:[^']|'')*)'", sql))[[1]]
  if (!length(m)) {
    stop("Rducks quack bridge: cannot read ENUM labels from ", sql, call. = FALSE)
  }
  gsub("''", "'", substr(m, 2L, nchar(m) - 1L))
}

rducks_quack_spec <- function(type) {
  kind <- rducks_quack_kind(type)
  id <- rducks_quack_ltype_ids[[kind]]
  if (kind == "decimal") {
    p <- rducks_quack_decimal_params(type)
    return(rducks_quack_spec_node(id, width = p$width, scale = p$scale))
  }
  if (kind == "enum") {
    return(rducks_quack_spec_node(id, enum_labels = rducks_quack_enum_labels(type)))
  }
  if (kind %in% c("list", "array", "struct", "map", "union")) {
    children <- rducks_type_children(type)
    child_names <- names(children) %||% rep("", length(children))
    specs <- lapply(children, rducks_quack_spec)
    names(specs) <- child_names
    if (kind == "map") {
      # MAP rides the wire as LIST(STRUCT(key, value)).
      entry <- rducks_quack_spec_node(
        rducks_quack_ltype_ids[["struct"]],
        children = stats::setNames(specs[seq_len(2L)], c("key", "value"))
      )
      return(rducks_quack_spec_node(id, children = list(child = entry)))
    }
    if (kind == "array") {
      return(rducks_quack_spec_node(id, array_size = rducks_quack_array_size(type),
                                    children = stats::setNames(specs[1L], "child")))
    }
    if (kind == "list") {
      return(rducks_quack_spec_node(id, children = stats::setNames(specs[1L], "child")))
    }
    return(rducks_quack_spec_node(id, children = specs))
  }
  if (kind %in% c("union", "variant")) {
    stop("Rducks quack bridge: ", toupper(kind),
         " is not on the Rducks wire yet", call. = FALSE)
  }
  rducks_quack_spec_node(id)
}

# ---- values <-> wire storage, via the native chunk IR ----

rducks_quack_storage_from_array <- function(array) {
  type <- array$type
  kind <- rducks_quack_kind(type)
  valid <- array$valid
  st <- array$storage
  data <- switch(kind,
    bool = ,
    i8 = , i16 = , i32 = , u8 = , u16 = , date = ,
    f32 = , f64 = , u32 = ,
    time = , time_tz = , timestamp = , timestamp_s = ,
    timestamp_ms = , timestamp_ns = , timestamp_tz = ,
    varchar = , uuid = ,
    i64 = , u64 = , hugeint = , uhugeint = , decimal = ,
    enum = st$values,
    blob = st$payloads,
    interval = list(months = st$months, days = st$days, micros = st$micros),
    list = list(offsets = st$offsets, lengths = st$lengths,
                child = rducks_quack_column_from_array(st$child)),
    map = list(offsets = st$offsets, lengths = st$lengths,
               child = rducks_quack_column_from_array(st$entries)),
    array = list(child = rducks_quack_column_from_array(st$child)),
    struct = lapply(st$fields, rducks_quack_column_from_array),
    stop("Rducks quack bridge: storage mapping for ", kind, " is not implemented", call. = FALSE)
  )
  list(valid = valid, data = data)
}

rducks_quack_column_from_array <- function(array) {
  rducks_quack_storage_from_array(array)
}

rducks_quack_array_from_storage <- function(type, column, rows) {
  kind <- rducks_quack_kind(type)
  valid <- column$valid %||% rep(TRUE, rows)
  data <- column$data
  storage <- switch(kind,
    bool = ,
    i8 = , i16 = , i32 = , u8 = , u16 = , date = ,
    f32 = , f64 = , u32 = ,
    time = , time_tz = , timestamp = , timestamp_s = ,
    timestamp_ms = , timestamp_ns = , timestamp_tz = ,
    varchar = , uuid = ,
    i64 = , u64 = , hugeint = , uhugeint = , decimal = ,
    enum = list(values = data),
    blob = list(payloads = data),
    interval = list(months = data$months, days = data$days, micros = data$micros),
    list = {
      children <- rducks_type_children(type)
      list(offsets = data$offsets, lengths = data$lengths,
           child = rducks_quack_array_from_storage(children[[1]], data$child,
                                                   length(data$child$valid %||% data$child$data)))
    },
    array = {
      children <- rducks_type_children(type)
      n_child <- rows * rducks_quack_array_size(type)
      list(child = rducks_quack_array_from_storage(children[[1]], data$child, n_child))
    },
    struct = {
      children <- rducks_type_children(type)
      fields <- Map(function(child_type, child_col) {
        rducks_quack_array_from_storage(child_type, child_col, rows)
      }, children, data)
      list(fields = fields)
    },
    stop("Rducks quack bridge: storage mapping for ", kind, " is not implemented", call. = FALSE)
  )
  rducks_native_array(type, rows, valid = valid, storage = storage)
}

# ---- chunk payloads ----

rducks_quack_encode_columns <- function(types, columns, rows) {
  specs <- lapply(types, rducks_quack_spec)
  .Call(RDUCKS_quack_encode_chunk, as.numeric(rows), specs, columns)
}

rducks_quack_decode_payload <- function(payload) {
  .Call(RDUCKS_quack_decode_chunk, payload)
}

# Materialize decoded wire columns to Rducks values for declared arg types.
rducks_quack_columns_to_values <- function(arg_types, decoded) {
  rows <- as.integer(decoded$rows)
  Map(function(type, column) {
    array <- rducks_quack_array_from_storage(type, column, rows)
    rducks_native_array_to_values(array)
  }, arg_types, decoded$columns)
}

# Dematerialize one result column to a single-column wire payload.
rducks_quack_results_payload <- function(return_type, results, rows) {
  array <- rducks_native_array_from_values(return_type, results, rows)
  column <- rducks_quack_storage_from_array(array)
  rducks_quack_encode_columns(list(return_type), list(column), rows)
}
