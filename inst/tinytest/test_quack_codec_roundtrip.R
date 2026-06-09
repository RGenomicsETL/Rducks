library(Rducks)

local({
  payload <- Rducks:::rducks_wire_encode_values(list(INTEGER), list(c(1L, NA_integer_, 3L)), 3L)
  expect_true(is.raw(payload))
  decoded <- Rducks:::rducks_wire_decode_values(list(INTEGER), payload)
  expect_equal(decoded$rows, 3L)
  expect_equal(decoded$values[[1]], c(1L, NA_integer_, 3L))

  payload2 <- Rducks:::rducks_wire_encode_values(list(VARCHAR), list(c("a", NA_character_, "c")), 3L)
  decoded2 <- Rducks:::rducks_wire_decode_values(list(VARCHAR), payload2)
  expect_equal(decoded2$values[[1]], c("a", NA_character_, "c"))
})
