rducks_scalar_udf_return_needs_length_one <- function(type) {
  if (rducks_type_inherits(type, c("rducks_decimal_type", "rducks_enum_type"))) {
    return(TRUE)
  }
  rducks_type_inherits(type, "rducks_scalar_type") &&
    !rducks_type_inherits(type, c(
      "rducks_blob_type", "rducks_geometry_type", "rducks_variant_type", "rducks_bit_type"
    ))
}

rducks_normalize_scalar_udf_return <- function(type, value) {
  if (rducks_type_inherits(type, "rducks_decimal_type") && inherits(value, "rducks_decimal")) {
    params <- rducks_type_parameters(type)
    return(rducks_decimal(as.character(value), params$width, params$scale))
  }
  value
}

rducks_check_scalar_udf_return <- function(type, value) {
  value <- rducks_normalize_scalar_udf_return(type, value)
  if (is.null(value)) {
    return(NULL)
  }
  rducks_check_return(type, value)
  if (rducks_scalar_udf_return_needs_length_one(type) && length(value) != 1L) {
    stop("return value must have length 1", call. = FALSE)
  }
  value
}
