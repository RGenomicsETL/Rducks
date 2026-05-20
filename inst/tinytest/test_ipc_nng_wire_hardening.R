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

payload <- as.raw(c(1, 2, 3))
tokens <- c("i32", "enum<a%7Cb|semi%3Bcolon>")
dynamic_payload <- c(
  Rducks:::rducks_nng_dynamic_payload_magic,
  Rducks:::rducks_nng_wire_u32(length(tokens)),
  Rducks:::rducks_nng_wire_u64(length(payload)),
  unlist(lapply(tokens, function(token) {
    token_raw <- charToRaw(token)
    c(Rducks:::rducks_nng_wire_u32(length(token_raw)), token_raw)
  }), use.names = FALSE),
  payload
)
decoded_dynamic <- Rducks:::rducks_nng_wire_decode_dynamic_payload(dynamic_payload)
expect_identical(decoded_dynamic$payload, payload)
expect_identical(decoded_dynamic$dynamic_arg_tokens, tokens)

udf_raw <- charToRaw("u")
dynamic_request <- c(
  Rducks:::rducks_nng_wire_magic,
  Rducks:::rducks_nng_wire_u32(Rducks:::rducks_nng_wire_version),
  Rducks:::rducks_nng_wire_u32(Rducks:::rducks_nng_wire_type_execute),
  Rducks:::rducks_nng_wire_u32(length(udf_raw)),
  Rducks:::rducks_nng_wire_u32(1L),
  Rducks:::rducks_nng_wire_u64(7L),
  Rducks:::rducks_nng_wire_u64(length(dynamic_payload)),
  udf_raw,
  dynamic_payload
)
decoded_request <- Rducks:::rducks_nng_wire_decode_request(dynamic_request)
expect_identical(decoded_request$payload, payload)
expect_identical(decoded_request$dynamic_arg_tokens, tokens)
expect_error(
  Rducks:::rducks_nng_wire_decode_dynamic_payload(charToRaw("not dynamic")),
  "invalid Rducks dynamic NNG payload"
)
