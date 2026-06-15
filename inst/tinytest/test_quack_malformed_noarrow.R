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

# Malformed nested (LIST) payloads must also error, not silently corrupt. The
# crafted payloads below depend on the exact wire byte layout, so each asserts
# its layout precondition explicitly (rather than silently skipping if a future
# encoder change shifts the bytes).

# A reordered LIST vector whose child (field 106) precedes its cardinality (field
# 104), combined with an entry that references rows the (empty) child does not
# hold, would decode to NA without the child-row-count vs cardinality check.
list_valid <- Rducks:::rducks_wire_encode_values(list(LIST(INTEGER)), list(list(integer(0))), 1L)
expect_equal(length(list_valid), 60L, info = "empty-LIST payload layout precondition")
attack <- list_valid
attack[44] <- as.raw(2L)                          # entry length 0 -> 2 (phantom rows)
size <- attack[33:35]; size[3] <- as.raw(2L)      # list cardinality 0 -> 2
attack <- c(attack[1:32], attack[36:56], size, attack[57:60])  # child before size
expect_error(
  Rducks:::rducks_wire_decode_values(list(LIST(INTEGER)), attack),
  pattern = "child row count disagrees with the declared cardinality",
  info = "reordered LIST with phantom child references must error, not return NA"
)

# A reordered LIST whose child carries data inconsistent with the late
# cardinality must also error (caught by the child payload-size check).
list_data <- Rducks:::rducks_wire_encode_values(list(LIST(INTEGER)), list(list(c(10L, 20L))), 1L)
expect_equal(length(list_data), 68L, info = "LIST(INTEGER) payload layout precondition")
reordered <- c(list_data[1:32], list_data[36:64], list_data[33:35], list_data[65:68])
expect_error(
  Rducks:::rducks_wire_decode_values(list(LIST(INTEGER)), reordered),
  info = "reordered LIST(INTEGER) with mismatched child must error"
)

# A list entry missing its length field must error (it would otherwise default to
# zero and silently drop rows). list_data's entry object is bytes 36..46
# (105 count1 | offset field100=0 | length field101=2 | end); drop the length.
expect_equal(as.integer(list_data[42:44]), c(0x65L, 0x00L, 0x02L),
             info = "list entry length field is where the layout precondition expects")
no_len <- c(list_data[1:41], list_data[45:68])
expect_error(
  Rducks:::rducks_wire_decode_values(list(LIST(INTEGER)), no_len),
  pattern = "list entry object is missing its offset or length",
  info = "list entry missing its length must error, not drop rows"
)

# Truncation fuzz over a nested LIST payload: no prefix may crash the process.
for (n in seq_len(length(list_data) - 1L)) {
  tryCatch(
    Rducks:::rducks_wire_decode_values(list(LIST(INTEGER)), list_data[seq_len(n)]),
    error = function(e) NULL
  )
}
expect_true(TRUE, info = "nested truncation fuzz completed without crashing")

# A duplicate payload field in a vector object must be rejected (it would
# otherwise overwrite an allocated buffer, leaking C heap).
one_int <- Rducks:::rducks_wire_encode_values(list(INTEGER), list(42L), 1L)
data_pat <- c(0x66L, 0x00L, 0x04L)  # field 102, length 4
di <- which(vapply(seq_len(length(one_int) - 2L),
                   function(i) all(as.integer(one_int[i:(i + 2L)]) == data_pat), logical(1)))
expect_equal(length(di), 1L, info = "single field-102 block present in the INTEGER payload")
block <- one_int[di:(di + 6L)]  # the 7-byte field-102 block (header + 4 data bytes)
dup <- c(one_int[seq_len(di + 6L)], block, one_int[(di + 7L):length(one_int)])
expect_error(
  Rducks:::rducks_wire_decode_values(list(INTEGER), dup),
  pattern = "duplicate field",
  info = "duplicate vector payload field must be rejected"
)

# A UNION result whose tag references a non-existent member must be rejected,
# never indexed out of range (defends the worker/external-response boundary).
union_t <- UNION(a = INTEGER, b = VARCHAR)
union_p <- Rducks:::rducks_wire_encode_values(list(union_t), list(list(rducks_union("a", 7L))), 1L)
tag_pat <- c(0x67L, 0x00L, 0x03L, 0x64L, 0x00L, 0x00L, 0x66L, 0x00L, 0x01L)  # struct children -> tag child data
ti <- which(vapply(seq_len(length(union_p) - length(tag_pat)),
                   function(i) all(as.integer(union_p[i:(i + length(tag_pat) - 1L)]) == tag_pat), logical(1)))
expect_equal(length(ti), 1L, info = "union tag child data block present in the payload")
attack2 <- union_p
attack2[ti + length(tag_pat)] <- as.raw(255L)  # tag 255 for a 2-member union
expect_error(
  Rducks:::rducks_wire_decode_values(list(union_t), attack2),
  pattern = "union tag references a non-existent member",
  info = "out-of-range union tag must be rejected"
)

# Top-level chunk object: duplicate fields must be rejected, not overwrite (and
# leak) the row count / type array / column array. The single-INTEGER chunk is
# rows(64 00 01) | types-field-101(65 00 01 + 5-byte INTEGER type) | columns...
one_chunk <- Rducks:::rducks_wire_encode_values(list(INTEGER), list(42L), 1L)
expect_equal(length(one_chunk), 28L, info = "single-INTEGER chunk layout precondition")
expect_equal(as.integer(one_chunk[4:6]), c(0x65L, 0x00L, 0x01L),
             info = "chunk types field (101) is where the layout precondition expects")
dup_types <- c(one_chunk[1:11], one_chunk[4:11], one_chunk[12:28])  # field 101 twice
expect_error(
  Rducks:::rducks_wire_decode_values(list(INTEGER), dup_types),
  pattern = "duplicate types field in quack chunk object",
  info = "duplicate chunk types field must be rejected"
)

# A struct member pair carrying a duplicate name field must be rejected (it would
# otherwise free-then-overwrite the first name, silently mutating the type). The
# member pair in STRUCT(a=INTEGER) is `00 00 | 01 61` (field 0 name "a"); inject a
# second copy of that 4-byte name field inside the same pair.
struct_p <- Rducks:::rducks_wire_encode_values(list(STRUCT(a = INTEGER)), list(list(list(a = 1L))), 1L)
expect_equal(as.integer(struct_p[19:22]), c(0x00L, 0x00L, 0x01L, 0x61L),
             info = "struct member-pair name field is where the layout precondition expects")
dup_name <- c(struct_p[1:22], struct_p[19:22], struct_p[23:length(struct_p)])
expect_error(
  Rducks:::rducks_wire_decode_values(list(STRUCT(a = INTEGER)), dup_name),
  pattern = "duplicate name in struct member pair",
  info = "duplicate struct member-pair name must be rejected"
)

# A vector advertising validity (field 100 flag = 1) but omitting the mask
# (field 101) must error rather than leave a NULL mask. The vector's has-validity
# flag value byte is at index 17 of this payload.
expect_equal(as.integer(one_chunk[15:17]), c(0x64L, 0x00L, 0x00L),
             info = "vector has-validity flag is where the layout precondition expects")
bad_validity <- one_chunk
bad_validity[17] <- as.raw(1L)  # advertise validity, but no mask field follows
expect_error(
  Rducks:::rducks_wire_decode_values(list(INTEGER), bad_validity),
  pattern = "advertises validity but is missing its mask",
  info = "has_validity without a mask must be rejected"
)

# The payload is self-describing, so a decoded wire type that disagrees with the
# declared signature must be rejected before any column is materialized (rather
# than silently reinterpreting the bytes under the declared type). The check uses
# the same canonical type equality the native result path uses.
int_p <- Rducks:::rducks_wire_encode_values(list(INTEGER), list(42L), 1L)
expect_error(
  Rducks:::rducks_wire_decode_values(list(VARCHAR), int_p),
  pattern = "type for column 1 disagrees with the declared signature",
  info = "wire type that disagrees with the declared type must be rejected"
)
str_p <- Rducks:::rducks_wire_encode_values(list(VARCHAR), list("42"), 1L)
expect_error(
  Rducks:::rducks_wire_decode_values(list(INTEGER), str_p),
  pattern = "type for column 1 disagrees with the declared signature",
  info = "reverse wire/declared type mismatch must also be rejected"
)
# A nested mismatch (LIST(INTEGER) wire vs declared LIST(VARCHAR)) is caught too.
listint_p <- Rducks:::rducks_wire_encode_values(list(LIST(INTEGER)), list(list(c(1L, 2L))), 1L)
expect_error(
  Rducks:::rducks_wire_decode_values(list(LIST(VARCHAR)), listint_p),
  pattern = "type for column 1 disagrees with the declared signature",
  info = "nested wire/declared type mismatch must be rejected"
)
# Column-count mismatch is reported by the same decoder gate.
expect_error(
  Rducks:::rducks_wire_decode_values(list(INTEGER, VARCHAR), int_p),
  pattern = "column count disagrees with the declared signature",
  info = "wire column count that disagrees with the declared arity must be rejected"
)
