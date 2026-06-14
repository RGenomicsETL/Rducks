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

  # Pure Quack codec round-trips for the container types, exercised in the
  # default suite (no IPC workers required): nested NULLs, empty entries.
  list_t <- LIST(INTEGER)
  list_v <- list(c(1L, NA_integer_, 3L), integer(0), NULL)
  expect_equal(
    Rducks:::rducks_wire_decode_values(list(list_t),
      Rducks:::rducks_wire_encode_values(list(list_t), list(list_v), 3L))$values[[1]],
    list_v
  )

  struct_t <- STRUCT(a = INTEGER, b = VARCHAR)
  struct_v <- list(list(a = 1L, b = "x"), NULL, list(a = NA_integer_, b = NA_character_))
  struct_d <- Rducks:::rducks_wire_decode_values(list(struct_t),
    Rducks:::rducks_wire_encode_values(list(struct_t), list(struct_v), 3L))$values[[1]]
  expect_equal(struct_d[[1]]$a, 1L)
  expect_null(struct_d[[2]])

  map_t <- MAP(INTEGER, VARCHAR)
  map_v <- list(list(keys = c(1L, 2L), values = c("a", "b")), NULL,
                list(keys = integer(0), values = character(0)))
  map_d <- Rducks:::rducks_wire_decode_values(list(map_t),
    Rducks:::rducks_wire_encode_values(list(map_t), list(map_v), 3L))$values[[1]]
  expect_equal(map_d[[1]]$keys, c(1L, 2L))
  expect_null(map_d[[2]])

  union_t <- UNION(a = INTEGER, b = VARCHAR)
  union_v <- list(rducks_union("a", 5L), rducks_union("b", "x"),
                  rducks_union("a", NA_integer_), NULL)
  union_d <- Rducks:::rducks_wire_decode_values(list(union_t),
    Rducks:::rducks_wire_encode_values(list(union_t), list(union_v), 4L))$values[[1]]
  expect_equal(union_d[[1]]$value, 5L)
  expect_equal(union_d[[2]]$value, "x")
  expect_equal(union_d[[3]]$tag, "a")   # active-but-NULL member keeps its tag
  expect_true(is.na(union_d[[3]]$value))
  expect_null(union_d[[4]])
})

# UNION is capped at DuckDB's 255-member limit at construction.
expect_error(
  do.call(UNION, stats::setNames(rep(list(INTEGER), 256L), paste0("m", seq_len(256L)))),
  pattern = "at most 255 members"
)
