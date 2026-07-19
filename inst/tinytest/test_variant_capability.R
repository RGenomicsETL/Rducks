library(Rducks)

# VARIANT support is conditional on the loaded DuckDB build. The extension
# obtains a canonical VARIANT type from the SQL binder, validates its complete
# physical layout, and proves that a data chunk exposes every nested vector via
# generic C APIs. The R type gates must track that runtime-reported capability
# rather than a hard-coded version assumption. This test is runtime-adaptive:
# incompatible runtimes remain fail-closed; capable runtimes must execute real
# direct scalar/vectorized, nested, and aggregate round trips.
local({
  if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE)) {
    exit_file("duckdb/DBI not available")
  }
  con <- DBI::dbConnect(duckdb::duckdb(config = list(
    allow_unsigned_extensions = "true",
    autoload_known_extensions = "false",
    autoinstall_known_extensions = "false"
  )))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  supported <- DBI::dbGetQuery(con, "SELECT rducks_variant_supported() AS ok")$ok[[1L]]
  expect_true(is.logical(supported) && length(supported) == 1L && !is.na(supported),
              info = "rducks_variant_supported() returns a single logical")

  # Direct and wire gates must agree with the same runtime capability.
  expect_equal(Rducks:::rducks_direct_mapping_supported(VARIANT), isTRUE(supported),
               info = "VARIANT direct mapping is gated on the runtime capability")
  expect_equal(Rducks:::rducks_wire_mapping_supported(VARIANT), isTRUE(supported),
               info = "VARIANT wire mapping is gated on the runtime capability")
  expect_equal(Rducks:::rducks_wire_mapping_supported(STRUCT(v = VARIANT)), isTRUE(supported),
               info = "nested VARIANT wire mapping uses the runtime capability recursively")

  if (isTRUE(supported)) {
    source <- "{'a': [1, NULL, 3], 'b': 'x'}::VARIANT"

    expect_silent(
      rducks_register_scalar_udf(con, "r_variant_id", function(x) x, args = VARIANT, returns = VARIANT)
    )
    scalar <- DBI::dbGetQuery(
      con,
      sprintf("SELECT r_variant_id(%s) IS NOT DISTINCT FROM %s AS v, r_variant_id(NULL::VARIANT) IS NULL AS n", source, source)
    )
    expect_true(scalar$v[[1L]], info = "direct scalar VARIANT preserves nested values")
    expect_true(scalar$n[[1L]], info = "direct scalar VARIANT preserves SQL NULL")

    primitive_exprs <- c(
      "TRUE::VARIANT", "FALSE::VARIANT",
      "1::TINYINT::VARIANT", "1::SMALLINT::VARIANT", "1::INTEGER::VARIANT",
      "1::BIGINT::VARIANT", "1::HUGEINT::VARIANT", "1::UTINYINT::VARIANT",
      "1::USMALLINT::VARIANT", "1::UINTEGER::VARIANT", "1::UBIGINT::VARIANT",
      "1::UHUGEINT::VARIANT", "1.25::FLOAT::VARIANT", "1.25::DOUBLE::VARIANT",
      "1.25::DECIMAL(8,2)::VARIANT", "'x'::VARCHAR::VARIANT", "'x'::BLOB::VARIANT",
      "'00000000-0000-0000-0000-000000000001'::UUID::VARIANT",
      "DATE '2020-01-01'::VARIANT", "TIME '12:34:56'::VARIANT",
      "TIMESTAMP '2020-01-01 12:34:56'::VARIANT",
      "INTERVAL '1 month 2 days 3 seconds'::VARIANT", "'101'::BIT::VARIANT"
    )
    primitives <- DBI::dbGetQuery(
      con,
      paste0(
        "SELECT count(*) AS n FROM (VALUES ",
        paste0("(", primitive_exprs, ")", collapse = ","),
        ") t(v) WHERE r_variant_id(v) IS DISTINCT FROM v"
      )
    )
    expect_equal(as.integer(primitives$n[[1L]]), 0L,
                 info = "direct VARIANT preserves every physical primitive family")

    expect_silent(
      rducks_register_scalar_udf(con, "r_variant_dynamic", function(x) x, returns = VARIANT)
    )
    dynamic <- DBI::dbGetQuery(
      con,
      sprintf("SELECT r_variant_dynamic(%s) IS NOT DISTINCT FROM %s AS v", source, source)
    )
    expect_true(dynamic$v[[1L]], info = "dynamic direct bind resolves VARIANT")

    expect_silent(
      rducks_register_scalar_udf(
        con, "r_variant_bad",
        function(x) {
          x$values[[1L]]$byte_offset <- 4294967295
          x
        },
        args = VARIANT, returns = VARIANT
      )
    )
    expect_error(
      DBI::dbGetQuery(con, "SELECT r_variant_bad(1::VARIANT)"),
      pattern = "Rducks RC return validation|byte_offset|payload exceeds",
      info = "malformed direct VARIANT output is rejected before DuckDB reads it"
    )

    expect_silent(
      rducks_register_scalar_udf(con, "r_variant_vec", function(x) x,
                                 args = VARIANT, returns = VARIANT, mode = "vectorized")
    )
    vectorized <- DBI::dbGetQuery(
      con,
      paste0("SELECT count(*) AS n FROM (VALUES (1::VARIANT), (NULL::VARIANT), (", source,
             ")) t(v) WHERE r_variant_vec(v) IS DISTINCT FROM v")
    )
    expect_equal(as.integer(vectorized$n[[1L]]), 0L,
                 info = "direct vectorized VARIANT preserves values and NULLs")

    nested_type <- STRUCT(v = VARIANT)
    expect_silent(
      rducks_register_scalar_udf(con, "r_variant_nested", function(x) x,
                                 args = nested_type, returns = nested_type)
    )
    nested <- DBI::dbGetQuery(
      con,
      sprintf("SELECT (r_variant_nested({v: %s})).v IS NOT DISTINCT FROM %s AS v", source, source)
    )
    expect_true(nested$v[[1L]], info = "nested direct VARIANT round trip")

    container_cases <- list(
      list(name = "r_variant_list", type = LIST(VARIANT),
           expr = sprintf("[1::VARIANT, %s, NULL::VARIANT]", source)),
      list(name = "r_variant_array", type = ARRAY(VARIANT, 2),
           expr = sprintf("[1::VARIANT, %s]::VARIANT[2]", source)),
      list(name = "r_variant_map", type = MAP(VARCHAR, VARIANT),
           expr = sprintf("MAP{'a': 1::VARIANT, 'b': %s}", source)),
      list(name = "r_variant_union", type = UNION(a = VARIANT, b = INTEGER),
           expr = sprintf("union_value(a := %s)", source))
    )
    for (case in container_cases) {
      expect_silent(
        rducks_register_scalar_udf(con, case$name, function(x) x,
                                   args = case$type, returns = case$type),
        info = paste0("register nested direct VARIANT: ", case$name)
      )
      round_trip <- DBI::dbGetQuery(
        con,
        sprintf("SELECT %s(%s) IS NOT DISTINCT FROM %s AS ok", case$name, case$expr, case$expr)
      )$ok[[1L]]
      expect_true(round_trip, info = paste0("nested direct VARIANT round trip: ", case$name))
    }

    expect_silent(
      rducks_register_aggregate(
        con, "r_variant_first",
        update = function(state, x) if (is.null(state)) x else state,
        finalize = function(state) state,
        args = VARIANT, returns = VARIANT
      )
    )
    aggregate <- DBI::dbGetQuery(
      con,
      sprintf("SELECT r_variant_first(v) IS NOT DISTINCT FROM %s AS v FROM (VALUES (%s), (2::VARIANT)) t(v)", source, source)
    )
    expect_true(aggregate$v[[1L]], info = "aggregate VARIANT result round trip")
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
