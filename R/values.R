# Value-level row extraction and NULL conventions, shared by the scalar and
# vectorized evaluators. These helpers operate purely on Rducks values, with no
# dependence on any particular marshalling buffer.

rducks_uses_r_null_for_null <- function(type) {
  rducks_type_inherits(type, c(
    "rducks_i64_type", "rducks_u64_type", "rducks_blob_type",
    "rducks_geometry_type", "rducks_variant_type",
    "rducks_hugeint_type", "rducks_uhugeint_type", "rducks_uuid_type",
    "rducks_interval_type", "rducks_bit_type"
  ))
}

rducks_value_at <- function(type, values, nulls, i) {
  if (isTRUE(nulls[[i]])) {
    if (rducks_uses_r_null_for_null(type) || !rducks_type_inherits(type, "rducks_scalar_type")) {
      return(NULL)
    }
  }
  if (rducks_type_inherits(type, "rducks_scalar_type")) {
    if (rducks_type_inherits(type, c("rducks_blob_type", "rducks_geometry_type", "rducks_variant_type", "rducks_bit_type"))) return(values[[i]])
    return(values[i])
  }
  if (rducks_type_inherits(type, c("rducks_decimal_type", "rducks_enum_type", "rducks_interval_type"))) {
    return(values[i])
  }
  if (rducks_type_inherits(type, "rducks_struct_type") && is.data.frame(values)) {
    row <- as.list(values[i, , drop = FALSE])
    children <- rducks_type_children(type)
    child_names <- rducks_type_child_names(type)
    for (field_index in seq_along(child_names)) {
      field <- child_names[[field_index]]
      child <- children[[field_index]]
      if ((!rducks_type_inherits(child, "rducks_scalar_type") || rducks_type_inherits(child, c("rducks_blob_type", "rducks_geometry_type", "rducks_variant_type", "rducks_bit_type"))) &&
          is.list(row[[field]]) && length(row[[field]]) == 1L) {
        # Single-bracket assignment so unwrapping a length-1 list whose element is
        # NULL keeps the field rather than deleting it from the row.
        row[field] <- row[[field]][1L]
      }
    }
    return(row)
  }
  if (rducks_type_inherits(type, "rducks_map_type")) {
    value <- values[[i]]
    if (is.data.frame(value)) {
      nms <- names(value)
      key_name <- if ("key" %in% nms) "key" else nms[[1L]]
      value_name <- if ("value" %in% nms) "value" else nms[[2L]]
      return(list(keys = value[[key_name]], values = value[[value_name]]))
    }
    return(value)
  }
  if (rducks_type_inherits(type, "rducks_union_type")) {
    value <- values[[i]]
    if (inherits(value, "rducks_union")) return(value)
    if (is.list(value) && !is.null(value$tag) && !is.null(value$value)) return(rducks_union(value$tag, value$value))
    return(value)
  }
  values[[i]]
}
