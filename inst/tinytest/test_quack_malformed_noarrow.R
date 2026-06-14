library(Rducks)

# Malformed wire payloads must be rejected with a clean R error, never a crash.
# This guards the decoder's per-type completeness validation: a structurally
# valid chunk whose vector omits its payload field previously produced a NULL
# dereference (segfault) during materialization / writeback.

# Hand-built chunk: rows = 1, one INTEGER (logical type id 13) column whose
# vector object closes immediately (no field 102 data).
incomplete_fixed <- as.raw(c(
  0x64, 0x00, 0x01,             # field 100: rows = 1
  0x65, 0x00, 0x01,             # field 101: ncolumns = 1
  0x64, 0x00, 0x0d, 0xff, 0xff, # type: field 100 id = 13 (INTEGER), object end
  0x66, 0x00, 0x01,             # field 102: vector count = 1
  0xff, 0xff,                   # vector 0: empty object (no data field)
  0xff, 0xff                    # chunk object end
))
expect_error(
  Rducks:::rducks_wire_decode_values(list(INTEGER), incomplete_fixed),
  pattern = "fixed-width vector is missing",
  info = "incomplete fixed-width vector must error, not crash"
)

# Truncating a valid payload at every length must error (or, for a complete
# prefix, decode) but never crash the process.
valid <- Rducks:::rducks_wire_encode_values(
  list(INTEGER, VARCHAR), list(c(1L, NA, 3L), c("a", "b", NA)), 3L
)
for (n in seq_len(length(valid) - 1L)) {
  tryCatch(
    Rducks:::rducks_wire_decode_values(list(INTEGER, VARCHAR), valid[seq_len(n)]),
    error = function(e) NULL
  )
}
# Reaching here means no truncated prefix crashed the process.
expect_true(TRUE, info = "truncation fuzz completed without crashing")

# The full valid payload still round-trips.
ok <- Rducks:::rducks_wire_decode_values(list(INTEGER, VARCHAR), valid)
expect_equal(ok$values[[1]], c(1L, NA, 3L))
expect_equal(ok$values[[2]], c("a", "b", NA))
