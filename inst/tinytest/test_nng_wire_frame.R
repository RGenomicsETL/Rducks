library(Rducks)

# NNG frame codec: the native request decoder / response encoder must agree
# with the R codec on well-formed frames, and decline (return NULL) anything
# malformed so the R decoder reports its usual error.
local({
  wire <- function(name) getFromNamespace(name, "Rducks")
  fast_decode <- function(buf) .Call(wire("RDUCKS_nng_wire_decode_request_fast"), buf)
  payload <- as.raw(c(0x10, 0x20, 0x30, 0x00, 0xff))

  buf <- wire("rducks_nng_wire_encode_request")(wire("rducks_nng_wire_type_execute"), "udf-1", 3, payload)
  expected <- list(type = 1L, udf_id = "udf-1", row_count = 3L, payload = payload, dynamic_arg_tokens = NULL)
  expect_identical(fast_decode(buf), expected)
  expect_identical(wire("rducks_nng_wire_decode_request")(buf), expected)

  # empty id and empty payload (ping/stop shaped frames)
  ping <- wire("rducks_nng_wire_encode_request")(wire("rducks_nng_wire_type_ping"))
  expect_identical(fast_decode(ping), list(type = 4L, udf_id = "", row_count = 0L, payload = raw(), dynamic_arg_tokens = NULL))

  # responses: encoded natively, decoded by the R decoder
  ok <- wire("rducks_nng_wire_encode_response")("ok", payload)
  expect_identical(wire("rducks_nng_wire_decode_response")(ok), list(status = "ok", error = "", payload = payload))
  err <- wire("rducks_nng_wire_encode_response")("error", raw(), "boom: café")
  decoded_err <- wire("rducks_nng_wire_decode_response")(err)
  expect_identical(decoded_err$status, "error")
  expect_identical(decoded_err$payload, raw())
  expect_identical(charToRaw(enc2utf8(decoded_err$error)), charToRaw(enc2utf8("boom: café")))
  expect_error(wire("rducks_nng_wire_encode_response")("maybe", raw()), pattern = "status must be")
  expect_error(wire("rducks_nng_wire_encode_response")("ok", "not raw"), pattern = "payload must be raw")

  # malformed request frames: native decoder declines, R decoder reports
  mutate <- function(buf, at, bytes) { buf[at] <- as.raw(bytes); buf }
  cases <- list(
    list(buf = buf[-length(buf)], pattern = "truncated Rducks NNG request frame"),
    list(buf = c(buf, as.raw(0)), pattern = "truncated Rducks NNG request frame"),
    list(buf = mutate(buf, 1L, 0x58), pattern = "invalid Rducks NNG request frame"),
    list(buf = mutate(buf, 5L, 0x02), pattern = "unsupported Rducks NNG request version"),
    list(buf = mutate(buf, 9L, 0x09), pattern = "unsupported Rducks NNG request type"),
    list(buf = mutate(buf, 17L, 0x02), pattern = "invalid Rducks NNG request reserved field"),
    list(buf = buf[seq_len(20)], pattern = "truncated Rducks NNG request frame")
  )
  for (case in cases) {
    expect_null(fast_decode(case$buf), info = case$pattern)
    expect_error(wire("rducks_nng_wire_decode_request")(case$buf), pattern = case$pattern)
  }
  nul_id <- mutate(buf, 36L + 2L, 0x00)
  expect_null(fast_decode(nul_id))
  expect_error(wire("rducks_nng_wire_decode_request")(nul_id), pattern = "nul")

  # dynamic-args frame (reserved = 1): native decoder declines, R decoder parses it
  tokens <- c("f64", "varchar")
  dyn_payload <- c(
    wire("rducks_nng_dynamic_payload_magic"),
    wire("rducks_nng_wire_u32")(length(tokens)),
    wire("rducks_nng_wire_u64")(length(payload)),
    unlist(lapply(tokens, function(t) c(wire("rducks_nng_wire_u32")(nchar(t)), charToRaw(t)))),
    payload
  )
  dyn <- wire("rducks_nng_wire_encode_request")(wire("rducks_nng_wire_type_execute"), "udf-2", 7, dyn_payload)
  dyn <- mutate(dyn, 17L, 0x01)
  expect_null(fast_decode(dyn))
  expect_identical(
    wire("rducks_nng_wire_decode_request")(dyn),
    list(type = 1L, udf_id = "udf-2", row_count = 7L, payload = payload, dynamic_arg_tokens = tokens)
  )

  # list-null helper
  expect_identical(.Call(wire("RDUCKS_list_is_null"), list(NULL, as.raw(1), NULL)), c(TRUE, FALSE, TRUE))
  expect_identical(.Call(wire("RDUCKS_list_is_null"), list()), logical())
})
