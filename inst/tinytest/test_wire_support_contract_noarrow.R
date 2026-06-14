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
  ENUM(c("a", "b")), ENUM(sprintf("e%04d", seq_len(300))), BIT,
  LIST(INTEGER), ARRAY(DOUBLE, 3), STRUCT(a = INTEGER, b = VARCHAR),
  LIST(LIST(INTEGER)), STRUCT(id = INTEGER, tags = LIST(VARCHAR)),
  ARRAY(STRUCT(x = INTEGER), 2)
)
for (type in supported) {
  expect_true(
    Rducks:::rducks_wire_mapping_supported(type),
    info = paste0("wire-supported: ", Rducks:::rducks_type_duckdb_sql(type))
  )
}

# Types the native worker bridge does not cover yet must report as unsupported
# so registration under the ipc plan rejects them instead of failing in a worker.
unsupported <- list(
  GEOMETRY, VARIANT, MAP(INTEGER, INTEGER), UNION(a = INTEGER, b = VARCHAR),
  # A supported container with an unsupported child is itself unsupported.
  LIST(MAP(INTEGER, INTEGER)), STRUCT(m = MAP(INTEGER, INTEGER)),
  ARRAY(VARIANT, 2)
)
for (type in unsupported) {
  expect_false(
    Rducks:::rducks_wire_mapping_supported(type),
    info = paste0("wire-unsupported: ", Rducks:::rducks_type_duckdb_sql(type))
  )
}
