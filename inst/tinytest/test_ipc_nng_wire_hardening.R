library(Rducks)

expect_equal(
  Rducks:::rducks_nng_wire_read_u32(Rducks:::rducks_nng_wire_u32(2^31 + 5), 1L)$value,
  2^31 + 5
)
expect_error(Rducks:::rducks_nng_wire_u32(-1), "uint32 value is out of range")
expect_error(Rducks:::rducks_nng_wire_u32(2^32), "uint32 value is out of range")
expect_error(Rducks:::rducks_nng_wire_u32(1.5), "uint32 value is out of range")

oversized_row_request <- Rducks:::rducks_nng_wire_encode_request(
  Rducks:::rducks_nng_wire_type_execute,
  udf_id = "u",
  row_count = .Machine$integer.max + 1,
  payload = raw()
)
expect_error(
  Rducks:::rducks_nng_wire_decode_request(oversized_row_request),
  "row count exceeds R integer range"
)

expect_error(
  Rducks:::rducks_nng_wire_encode_request(999L),
  "unsupported Rducks NNG request type"
)
expect_error(
  Rducks:::rducks_nng_wire_encode_response("maybe"),
  "status must be 'ok' or 'error'"
)
expect_identical(Rducks:::rducks_as_raw_payload(c(0, 1, 255)), as.raw(c(0, 1, 255)))
expect_error(
  Rducks:::rducks_as_raw_payload(c(0, 256)),
  "byte-valued"
)
