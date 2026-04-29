library(Rducks)

expect_equal(rducks_type_normalize("integer"), "i32")
expect_equal(rducks_duckdb_types(c("i32", "f64", "varchar")), c("INTEGER", "DOUBLE", "VARCHAR"))
expect_equal(rducks_duckdb_signature("f", c("i32", "f64"), "bool"), "f(INTEGER, DOUBLE) -> BOOLEAN")

spec <- rducks_udf_spec("plus_one", function(x) x + 1, "f64", "f64", mode = "compiled")
expect_inherits(spec, "rducks_udf_spec")
expect_equal(spec$signature, "plus_one(DOUBLE) -> DOUBLE")

src <- rducks_generate_scalar_wrapper(spec)
expect_true(grepl("rducks_wrap_plus_one", src, fixed = TRUE))
expect_true(grepl("double a0", src, fixed = TRUE))
expect_true(grepl("rducks_call_callback", src, fixed = TRUE))

cb <- rducks_callback(function(x, y) x + y)
expect_inherits(cb, "rducks_callback")
expect_equal(rducks_callback_invoke(cb, list(2, 3)), 5)
rducks_callback_close(cb)

expect_equal(rducks_pump(), 0L)
