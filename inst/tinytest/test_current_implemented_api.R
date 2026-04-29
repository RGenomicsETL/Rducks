library(Rducks)

expect_equal(rducks_type_normalize("integer"), "i32")
expect_equal(rducks_duckdb_types(c("i32", "f64", "varchar")), c("INTEGER", "DOUBLE", "VARCHAR"))
expect_equal(rducks_duckdb_signature("f", c("i32", "f64"), "bool"), "f(INTEGER, DOUBLE) -> BOOLEAN")

cb <- rducks_callback(function(x, y) x + y)
expect_inherits(cb, "rducks_callback")
expect_equal(rducks_callback_invoke(cb, list(2, 3)), 5)
rducks_callback_close(cb)

expect_error(rducks_pump(), "not implemented yet")
