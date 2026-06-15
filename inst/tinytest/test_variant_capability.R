library(Rducks)

# VARIANT support is conditional on the loaded DuckDB build: the extension
# reports, via rducks_variant_supported(), whether the runtime C API exposes a
# creatable VARIANT logical type AND the extension implements VARIANT
# materialization. The R type gate must track that runtime-reported capability
# rather than a hard-coded assumption. This test is runtime-adaptive: on a build
# without VARIANT support (e.g. DuckDB whose C API predates it) it asserts the
# rejection; on a capable build it asserts the gate opens.
local({
  if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE)) {
    exit_file("duckdb/DBI not available")
  }
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  supported <- DBI::dbGetQuery(con, "SELECT rducks_variant_supported() AS ok")$ok[[1L]]
  expect_true(is.logical(supported) && length(supported) == 1L && !is.na(supported),
              info = "rducks_variant_supported() returns a single logical")

  # The direct-mapping gate must agree with the runtime-reported capability.
  expect_equal(Rducks:::rducks_direct_mapping_supported(VARIANT), isTRUE(supported),
               info = "VARIANT direct mapping is gated on the runtime capability")

  if (isTRUE(supported)) {
    expect_silent(
      rducks_register_scalar_udf(con, "r_variant_id", function(x) x, args = VARIANT, returns = VARIANT)
    )
  } else {
    # Every registration path must reject VARIANT consistently, not just the
    # scalar direct path: nested VARIANT, and the aggregate path (which has no
    # execution plan and so bypasses the scalar/wire type gates).
    expect_error(
      rducks_register_scalar_udf(con, "r_variant_arg", function(x) x, args = VARIANT, returns = INTEGER),
      pattern = "VARIANT",
      info = "scalar VARIANT is rejected when the runtime cannot carry it"
    )
    expect_error(
      rducks_register_scalar_udf(con, "r_variant_nested", function(x) x,
                                 args = STRUCT(v = VARIANT), returns = INTEGER),
      pattern = "VARIANT",
      info = "nested VARIANT (STRUCT(v = VARIANT)) is rejected"
    )
    expect_error(
      rducks_register_aggregate(con, "r_variant_agg",
                                update = function(state, x) x,
                                finalize = function(state) state,
                                args = VARIANT, returns = VARIANT),
      pattern = "VARIANT",
      info = "aggregate VARIANT is rejected when the runtime cannot carry it"
    )
  }
})
