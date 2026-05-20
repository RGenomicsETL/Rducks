library(Rducks)

local({
  schema <- nanoarrow::nanoarrow_schema_modify(
    nanoarrow::infer_nanoarrow_schema(logical()),
    list(format = "c", metadata = list("ARROW:extension:name" = "arrow.bool8"))
  )
  values <- c(TRUE, FALSE, NA, TRUE)
  array <- Rducks:::rducks_arrow_scalar_values_to_array(BOOLEAN, values, schema)
  expect_equal(nanoarrow::nanoarrow_schema_parse(schema)$extension_name, "arrow.bool8")
  expect_equal(as.integer(as.raw(array$buffers[[2L]])[seq_along(values)]), c(1L, 0L, 255L, 1L))
  roundtrip <- Rducks:::rducks_arrow_scalar_array_to_values(BOOLEAN, array, schema)
  expect_equal(roundtrip, values)
})
