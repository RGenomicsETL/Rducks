library(Rducks)

local({
  arr <- nanoarrow::as_nanoarrow_array(c(1L, NA_integer_, 3L))
  expect_equal(Rducks:::rducks_arrow_validity(arr), c(TRUE, FALSE, TRUE))

  all_valid <- nanoarrow::as_nanoarrow_array(1:3)
  expect_equal(Rducks:::rducks_arrow_validity(all_valid), rep(TRUE, 3))

  empty <- nanoarrow::as_nanoarrow_array(integer())
  expect_equal(Rducks:::rducks_arrow_validity(empty), logical())
})

local({
  validity <- c(FALSE, TRUE, FALSE, TRUE, TRUE, FALSE, TRUE, FALSE, TRUE)
  raw_validity <- Rducks:::rducks_arrow_pack_bits(validity)
  synthetic <- list(buffers = list(raw_validity), length = length(validity), offset = 0L)
  expect_equal(Rducks:::rducks_arrow_validity(synthetic), validity)

  offset_synthetic <- list(buffers = list(raw_validity), length = 4L, offset = 2L)
  expect_equal(Rducks:::rducks_arrow_validity(offset_synthetic), validity[3:6])

  short_synthetic <- list(buffers = list(as.raw(1L)), length = 9L, offset = 0L)
  expect_error(
    Rducks:::rducks_arrow_validity(short_synthetic),
    "shorter than array length plus offset"
  )

  bad_offset <- list(buffers = list(raw_validity), length = 1L, offset = -1L)
  expect_error(Rducks:::rducks_arrow_validity(bad_offset), "invalid Arrow array length or offset")
})
