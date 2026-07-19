library(Rducks)

# VARIANT output bypasses DuckDB's cast machinery and writes the validated
# physical storage directly. Reject malformed metadata in R before DuckDB can
# dereference an invalid child index or byte offset.
int_variant <- list(
  keys = character(),
  children = list(),
  values = list(list(type_id = 5L, byte_offset = 0)),
  data = as.raw(c(42, 0, 0, 0))
)
expect_true(inherits(rducks_variant(int_variant), "rducks_variant"))

object_variant <- list(
  keys = "a",
  children = list(list(keys_index = 0, values_index = 1)),
  values = list(
    list(type_id = 29L, byte_offset = 0),
    list(type_id = 5L, byte_offset = 2)
  ),
  # OBJECT child_count=1, children_start=0, then one INT32 payload.
  data = as.raw(c(1, 0, 42, 0, 0, 0))
)
expect_true(inherits(rducks_variant(object_variant), "rducks_variant"))

bad_type <- int_variant
bad_type$values[[1L]]$type_id <- 34L
expect_error(rducks_variant(bad_type), pattern = "invalid type_id")

bad_root <- int_variant
bad_root$values[[1L]]$type_id <- 0L
expect_error(rducks_variant(bad_root), pattern = "root must not use VARIANT_NULL")

bad_fixed <- int_variant
bad_fixed$data <- raw(3L)
expect_error(rducks_variant(bad_fixed), pattern = "fixed payload exceeds")

bad_offset <- int_variant
bad_offset$values[[1L]]$byte_offset <- 99
expect_error(rducks_variant(bad_offset), pattern = "out-of-bounds byte_offset")

bad_child <- object_variant
bad_child$children[[1L]]$values_index <- 2
expect_error(rducks_variant(bad_child), pattern = "out-of-bounds values_index")

bad_object_key <- object_variant
bad_object_key$children[[1L]]$keys_index <- NA_real_
expect_error(rducks_variant(bad_object_key), pattern = "OBJECT children require keys")

bad_range <- object_variant
bad_range$data[[1L]] <- as.raw(2L)
expect_error(rducks_variant(bad_range), pattern = "child range exceeds")

bad_cycle <- object_variant
bad_cycle$children[[1L]]$values_index <- 0
expect_error(rducks_variant(bad_cycle), pattern = "cyclic or backward child reference")

bad_varlen <- int_variant
bad_varlen$values[[1L]]$type_id <- 16L
bad_varlen$data <- as.raw(c(5, 1, 2))
expect_error(rducks_variant(bad_varlen), pattern = "variable payload exceeds")

bad_varint <- int_variant
bad_varint$values[[1L]]$type_id <- 16L
bad_varint$data <- as.raw(rep(0x80, 5L))
expect_error(rducks_variant(bad_varint), pattern = "oversized VARIANT varint")
