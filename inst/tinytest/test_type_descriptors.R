library(Rducks)

nested <- STRUCT(
  id = INTEGER,
  label = ENUM(c("low", "high")),
  payload = UNION(code = INTEGER, note = VARCHAR),
  values = LIST(DECIMAL(10, 2))
)

expect_true(rducks_is_type(INTEGER))
expect_true(rducks_is_type(DECIMAL(10, 2)))
expect_true(rducks_is_type(nested))

expect_false(rducks_is_type(list(token = "INTEGER")))
forged <- structure(
  list(token = "INTEGER", duckdb_sql = "INTEGER", kind = "scalar",
       children = list(), child_names = character(), size = NA_integer_,
       parameters = list()),
  class = class(INTEGER)
)
expect_false(rducks_is_type(forged))
expect_false(rducks_is_type(1L))
