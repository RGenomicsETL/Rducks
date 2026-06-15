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
  timestamp_tz = 32L, time_tz = 34L, bit = 36L, geometry = 26L,
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
  # VARIANT is not on the wire yet; reject up front so no half-built spec is
  # constructed for it (registration already blocks it).
  if (kind == "variant") {
    stop("Rducks quack bridge: VARIANT is not on the Rducks wire yet", call. = FALSE)
  }
  if (kind == "union") {
    # UNION rides the wire as DuckDB's physical STRUCT(tag UTINYINT, members...);
    # the explicit tag avoids the active-but-NULL member ambiguity.
    children <- rducks_type_children(type)
    member_names <- rducks_type_child_names(type)
    specs <- c(
      list(rducks_quack_spec_node(rducks_quack_ltype_ids[["u8"]])),
      lapply(children, rducks_quack_spec)
    )
    names(specs) <- c("", member_names)
    return(rducks_quack_spec_node(rducks_quack_ltype_ids[["struct"]], children = specs))
  }
  id <- rducks_quack_ltype_ids[[kind]]
  if (kind == "decimal") {
    p <- rducks_quack_decimal_params(type)
    return(rducks_quack_spec_node(id, width = p$width, scale = p$scale))
  }
  if (kind == "enum") {
    return(rducks_quack_spec_node(id, enum_labels = rducks_quack_enum_labels(type)))
  }
  if (kind == "map") {
    # MAP rides the wire as LIST(STRUCT(key, value)).
    children <- rducks_type_children(type)
    specs <- lapply(children, rducks_quack_spec)
    entry <- rducks_quack_spec_node(
      rducks_quack_ltype_ids[["struct"]],
      children = stats::setNames(specs[seq_len(2L)], c("key", "value"))
    )
    return(rducks_quack_spec_node(id, children = stats::setNames(list(entry), "child")))
  }
  if (kind %in% c("list", "array", "struct")) {
    children <- rducks_type_children(type)
    child_names <- names(children) %||% rep("", length(children))
    specs <- lapply(children, rducks_quack_spec)
    names(specs) <- child_names
    if (kind == "array") {
      return(rducks_quack_spec_node(id, array_size = rducks_quack_array_size(type),
                                    children = stats::setNames(specs[1L], "child")))
    }
    if (kind == "list") {
      return(rducks_quack_spec_node(id, children = stats::setNames(specs[1L], "child")))
    }
    return(rducks_quack_spec_node(id, children = specs))
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
    blob = ,
    geometry = ,
    bit = st$payloads,
    interval = list(months = st$months, days = st$days, micros = st$micros),
    list = list(offsets = as.numeric(st$offsets), lengths = as.numeric(st$lengths),
                child = rducks_quack_column_from_array(st$child)),
    # MAP rides as LIST(STRUCT(key, value)): combine the separate key/value child
    # arrays into a single struct entry column for the wire.
    map = {
      entry <- list(
        valid = NULL,
        data = stats::setNames(
          list(rducks_quack_column_from_array(st$keys), rducks_quack_column_from_array(st$values)),
          c("key", "value")
        )
      )
      list(offsets = as.numeric(st$offsets), lengths = as.numeric(st$lengths), child = entry)
    },
    array = list(child = rducks_quack_column_from_array(st$child)),
    struct = lapply(st$fields, rducks_quack_column_from_array),
    # UNION rides as STRUCT(tag UTINYINT, members...): child 0 is the 0-based tag
    # (native tags are 1-based; NULL union rows carry NA, marked null by the tag
    # column and the union-level validity), children 1..n are the member columns.
    union = c(
      list(list(valid = NULL, data = as.integer(st$tags - 1L))),
      lapply(st$members, rducks_quack_column_from_array)
    ),
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
    blob = ,
    geometry = ,
    bit = list(payloads = data),
    interval = list(months = data$months, days = data$days, micros = data$micros),
    list = {
      children <- rducks_type_children(type)
      # The child's decoded row count is carried on the child column (the C
      # decoder records it), which is robust for nested children whose extent
      # cannot be read off a flat data length.
      child_rows <- as.integer(data$child$rows %||% 0)
      list(offsets = data$offsets, lengths = data$lengths,
           child = rducks_quack_array_from_storage(children[[1]], data$child, child_rows))
    },
    map = {
      children <- rducks_type_children(type)
      # The entry child is a struct(key, value) column; split it back into the
      # separate key/value child arrays the native map storage uses.
      entry_rows <- as.integer(data$child$rows %||% 0)
      key_col <- data$child$data[[1L]]
      value_col <- data$child$data[[2L]]
      list(offsets = data$offsets, lengths = data$lengths,
           keys = rducks_quack_array_from_storage(children[[1L]], key_col,
                                                  as.integer(key_col$rows %||% entry_rows)),
           values = rducks_quack_array_from_storage(children[[2L]], value_col,
                                                    as.integer(value_col$rows %||% entry_rows)))
    },
    array = {
      children <- rducks_type_children(type)
      child_rows <- as.integer(data$child$rows %||% (rows * rducks_quack_array_size(type)))
      list(size = rducks_quack_array_size(type),
           child = rducks_quack_array_from_storage(children[[1]], data$child, child_rows))
    },
    struct = {
      children <- rducks_type_children(type)
      fields <- Map(function(child_type, child_col) {
        rducks_quack_array_from_storage(child_type, child_col, as.integer(child_col$rows %||% rows))
      }, children, data)
      list(fields = fields)
    },
    # UNION arrives as STRUCT(tag, members...): child 0 is the 0-based tag,
    # children 1..n are the members. Rebuild 1-based tags and member arrays.
    union = {
      children <- rducks_type_children(type)
      tag_col <- data[[1L]]
      tag_vals <- rducks_native_array_to_values(
        rducks_quack_array_from_storage(rducks_as_type(UTINYINT), tag_col,
                                        as.integer(tag_col$rows %||% rows))
      )
      tags <- ifelse(is.na(tag_vals), NA_integer_, as.integer(tag_vals) + 1L)
      if (any(!is.na(tags) & (tags < 1L | tags > length(children)))) {
        stop("Rducks quack bridge: union tag references a non-existent member", call. = FALSE)
      }
      members <- lapply(seq_along(children), function(j) {
        mc <- data[[j + 1L]]
        rducks_quack_array_from_storage(children[[j]], mc, as.integer(mc$rows %||% rows))
      })
      list(tags = tags, members = members)
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

rducks_quack_decode_payload <- function(payload, expected = NULL) {
  .Call(RDUCKS_quack_decode_chunk, payload, expected)
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
  array <- rducks_native_array_from_values(return_type, results)
  column <- rducks_quack_storage_from_array(array)
  rducks_quack_encode_columns(list(return_type), list(column), rows)
}
