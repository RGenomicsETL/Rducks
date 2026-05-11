library(Rducks)

ok <- Rducks:::rducks_nng_wire_encode_response("ok", raw())
expect_true(Rducks:::rducks_nng_response_frame_ready(ok))
expect_false(Rducks:::rducks_nng_response_frame_ready(raw()))
expect_false(Rducks:::rducks_nng_response_frame_ready(ok[seq_len(8L)]))

summary0 <- Rducks:::rducks_nng_response_summary(raw())
expect_true(grepl("length=0", summary0, fixed = TRUE))

decoded <- Rducks:::rducks_nng_decode_response_checked(ok, "inproc://unit", "unit")
expect_equal(decoded$status, "ok")
expect_equal(decoded$payload, raw())

err <- tryCatch(
  Rducks:::rducks_nng_decode_response_checked(raw(), "inproc://unit", "unit"),
  error = conditionMessage
)
expect_true(is.character(err))
expect_true(grepl("failed to decode Rducks NNG unit response", err, fixed = TRUE))
expect_true(grepl("length=0", err, fixed = TRUE))
