library(Rducks)

# Contract test for the Quack wire (ipc) type-support predicate. This needs no
# workers: it pins exactly which types the `ipc` transport advertises so the
# support matrix, registration validation, and native bridge cannot silently
# drift apart. Update this list and the native bridge together.

supported <- list(
  BOOLEAN, TINYINT, UTINYINT, SMALLINT, USMALLINT, INTEGER, UINTEGER,
  BIGINT, UBIGINT, FLOAT, DOUBLE, VARCHAR, BLOB, DATE, TIME, TIMESTAMP,
  HUGEINT, UHUGEINT, UUID, INTERVAL,
  DECIMAL(4, 2), DECIMAL(9, 3), DECIMAL(18, 4), DECIMAL(30, 5),
  ENUM(c("a", "b")), ENUM(sprintf("e%04d", seq_len(300))), BIT, GEOMETRY,
  LIST(INTEGER), ARRAY(DOUBLE, 3), STRUCT(a = INTEGER, b = VARCHAR),
  LIST(LIST(INTEGER)), STRUCT(id = INTEGER, tags = LIST(VARCHAR)),
  ARRAY(STRUCT(x = INTEGER), 2), LIST(GEOMETRY),
  MAP(INTEGER, VARCHAR), LIST(MAP(INTEGER, INTEGER)), MAP(VARCHAR, STRUCT(a = INTEGER)),
  UNION(a = INTEGER, b = VARCHAR), STRUCT(u = UNION(a = INTEGER)), MAP(INTEGER, UNION(a = INTEGER))
)
for (type in supported) {
  expect_true(
    Rducks:::rducks_wire_mapping_supported(type),
    info = paste0("wire-supported: ", Rducks:::rducks_type_duckdb_sql(type))
  )
}

# VARIANT and containers that contain it recursively follow the runtime probe.
# The default before rducks_enable() is fail-closed; a capable loaded runtime
# enables all of these signatures together.
variant_supported <- Rducks:::rducks_variant_runtime_supported()
variant_types <- list(
  VARIANT, LIST(VARIANT), STRUCT(v = VARIANT), ARRAY(VARIANT, 2),
  MAP(INTEGER, VARIANT), UNION(a = VARIANT), LIST(STRUCT(v = VARIANT))
)
for (type in variant_types) {
  expect_equal(
    Rducks:::rducks_wire_mapping_supported(type),
    variant_supported,
    info = paste0("wire runtime-gated: ", Rducks:::rducks_type_duckdb_sql(type))
  )
}
