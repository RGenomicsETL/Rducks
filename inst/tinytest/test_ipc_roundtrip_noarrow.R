library(Rducks)

# Worker-process (ipc) roundtrip over the Quack wire codec. Spawns mirai daemons,
# so it is gated behind RDUCKS_RUN_IPC_TESTS to keep the default check/CRAN run
# free of worker-process orchestration. The gate must stay at file top level:
# `exit_file()` only aborts the file when called outside a function/local().
if (!identical(tolower(Sys.getenv("RDUCKS_RUN_IPC_TESTS", "")), "true")) {
  exit_file("ipc roundtrip test disabled (set RDUCKS_RUN_IPC_TESTS=true)")
}
if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE) ||
    !requireNamespace("mirai", quietly = TRUE) || !requireNamespace("nanonext", quietly = TRUE)) {
  exit_file("ipc dependencies not available")
}

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  on.exit(rducks_release(con), add = TRUE)

  plan <- rducks_execution_plan("ipc", ipc_workers = 2L, ipc_timeout = 60)
  expect_equal(plan$engine_id, "ipc_nng_pool")

  # Register single-threaded under the ipc plan (starts workers + broadcasts UDF).
  rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)

  # Every advertised wire scalar type: identity UDF + a value expression that
  # mixes a SQL NULL into the column. `IS DISTINCT FROM` checks both the value
  # roundtrip and NULL preservation in one predicate (NULL is not distinct from
  # NULL). Each case registers under threads=1 so the UDF is broadcast to workers.
  cases <- list(
    list(name = "id_bool",   type = BOOLEAN,   expr = "(i % 2 = 0)"),
    list(name = "id_i8",     type = TINYINT,   expr = "((i % 120) - 60)::TINYINT"),
    list(name = "id_u8",     type = UTINYINT,  expr = "(i % 200)::UTINYINT"),
    list(name = "id_i16",    type = SMALLINT,  expr = "(i - 4000)::SMALLINT"),
    list(name = "id_u16",    type = USMALLINT, expr = "(i % 60000)::USMALLINT"),
    list(name = "id_i32",    type = INTEGER,   expr = "(i - 4000)::INTEGER"),
    list(name = "id_u32",    type = UINTEGER,  expr = "(i * 7)::UINTEGER"),
    list(name = "id_i64",    type = BIGINT,    expr = "(i * 1000000)::BIGINT"),
    list(name = "id_u64",    type = UBIGINT,   expr = "(i * 1000000)::UBIGINT"),
    list(name = "id_f32",    type = FLOAT,     expr = "(i * 0.5)::FLOAT"),
    list(name = "id_f64",    type = DOUBLE,    expr = "(i * 0.25)::DOUBLE"),
    list(name = "id_str",    type = VARCHAR,   expr = "('v' || i)"),
    list(name = "id_blob",   type = BLOB,      expr = "encode('b' || i)"),
    list(name = "id_date",   type = DATE,      expr = "(DATE '2020-01-01' + i::INTEGER)"),
    list(name = "id_time",   type = TIME,      expr = "(TIME '00:00:00' + to_seconds(i % 86400))"),
    list(name = "id_ts",     type = TIMESTAMP, expr = "(TIMESTAMP '2020-01-01' + to_seconds(i))"),
    list(name = "id_hugeint",  type = HUGEINT,  expr = "((i)::HUGEINT * 1000000000000000000)"),
    list(name = "id_uhugeint", type = UHUGEINT, expr = "((i)::UHUGEINT * 1000000000000000000)"),
    list(name = "id_uuid",   type = UUID,
         expr = "('00000000-0000-0000-0000-' || lpad(i::VARCHAR, 12, '0'))::UUID")
  )
  for (case in cases) {
    rducks_register_scalar_udf(con, case$name, function(x) x,
                               args = list(case$type), returns = case$type)
  }

  # Bump DuckDB threads for concurrent off-main execution -> NNG worker roundtrip.
  rducks_set_execution_plan(con, plan, threads = 3L, external_threads = 2L)

  for (case in cases) {
    # Mix a NULL into the column so each query exercises value + NULL paths.
    valexpr <- sprintf("CASE WHEN i %% 7 = 0 THEN NULL ELSE %s END", case$expr)
    sql <- sprintf(
      "SELECT count(*) c FROM (SELECT %s v FROM range(4000) t(i)) s WHERE %s(v) IS DISTINCT FROM v",
      valexpr, case$name
    )
    mismatch <- DBI::dbGetQuery(con, sql)$c
    expect_equal(as.integer(mismatch), 0L, info = paste0("ipc roundtrip: ", case$name))
  }

  # Gated types must be rejected at registration under the ipc plan, not fail
  # later in a worker. The native bridge does not cover them yet.
  rejected <- list(
    list(name = "rej_decimal",  type = DECIMAL(10, 2)),
    list(name = "rej_interval", type = INTERVAL),
    list(name = "rej_enum",     type = ENUM(c("a", "b"))),
    list(name = "rej_geometry", type = GEOMETRY),
    list(name = "rej_bit",      type = BIT),
    list(name = "rej_list",     type = LIST(INTEGER)),
    list(name = "rej_struct",   type = STRUCT(a = INTEGER))
  )
  for (case in rejected) {
    expect_error(
      rducks_register_scalar_udf(con, case$name, function(x) x,
                                 args = list(case$type), returns = case$type),
      info = paste0("ipc registration must reject: ", case$name)
    )
  }
})
