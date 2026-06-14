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

# Malformed nested (LIST) payloads must also error, not silently corrupt. A
# reordered LIST vector whose child (field 106) precedes its cardinality (field
# 104), combined with an entry that references rows the (empty) child does not
# hold, would decode to NA without the child-row-count vs cardinality check.
list_valid <- Rducks:::rducks_wire_encode_values(list(LIST(INTEGER)), list(list(integer(0))), 1L)
if (length(list_valid) == 60L) {
  attack <- list_valid
  attack[44] <- as.raw(2L)                          # entry length 0 -> 2 (phantom rows)
  size <- attack[33:35]; size[3] <- as.raw(2L)      # list cardinality 0 -> 2
  attack <- c(attack[1:32], attack[36:56], size, attack[57:60])  # child before size
  expect_error(
    Rducks:::rducks_wire_decode_values(list(LIST(INTEGER)), attack),
    pattern = "child row count disagrees with the declared cardinality",
    info = "reordered LIST with phantom child references must error, not return NA"
  )
}

# A reordered LIST whose child carries data inconsistent with the late
# cardinality must also error (caught by the child payload-size check).
list_data <- Rducks:::rducks_wire_encode_values(list(LIST(INTEGER)), list(list(c(10L, 20L))), 1L)
if (length(list_data) == 68L) {
  reordered <- c(list_data[1:32], list_data[36:64], list_data[33:35], list_data[65:68])
  expect_error(
    Rducks:::rducks_wire_decode_values(list(LIST(INTEGER)), reordered),
    info = "reordered LIST(INTEGER) with mismatched child must error"
  )
}

# Truncation fuzz over a nested LIST payload: no prefix may crash the process.
for (n in seq_len(length(list_data) - 1L)) {
  tryCatch(
    Rducks:::rducks_wire_decode_values(list(LIST(INTEGER)), list_data[seq_len(n)]),
    error = function(e) NULL
  )
}
expect_true(TRUE, info = "nested truncation fuzz completed without crashing")
