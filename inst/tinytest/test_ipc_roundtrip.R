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
         expr = "('00000000-0000-0000-0000-' || lpad(i::VARCHAR, 12, '0'))::UUID"),
    # DECIMAL across all four physical storage widths (2/4/8/16 bytes).
    list(name = "id_dec2",   type = DECIMAL(4, 2),
         expr = "((mod(i, 199) - 99)::DECIMAL(4, 2))"),
    list(name = "id_dec4",   type = DECIMAL(9, 3),
         expr = "((mod(i, 999999) - 500000)::DECIMAL(9, 3))"),
    list(name = "id_dec8",   type = DECIMAL(12, 3),
         expr = "(mod(i, 1000000)::DECIMAL(12, 3))"),
    list(name = "id_dec16",  type = DECIMAL(30, 5),
         expr = "(i::DECIMAL(30, 5) * 100000)"),
    list(name = "id_int",    type = INTERVAL,
         expr = "(to_seconds(mod(i, 1000)) + to_days(mod(i, 30)::INTEGER) + to_months(mod(i, 12)::INTEGER))"),
    # BIT with bit-string lengths 1..24 so padding crosses byte boundaries.
    list(name = "id_bit",    type = BIT,
         expr = "(substr((mod(i, 255) + 1)::BIT::VARCHAR, 1, mod(i, 24) + 1))::BIT")
  )
  for (case in cases) {
    rducks_register_scalar_udf(con, case$name, function(x) x,
                               args = list(case$type), returns = case$type)
  }

  # ENUM needs a declared DuckDB type, so it is exercised separately from the
  # inline range() cases. Cover a small dictionary (1-byte index storage) and a
  # large one (>255 labels -> 2-byte index storage), both with NULLs. Register
  # under threads=1 with the other UDFs before the concurrency bump.
  small_levels <- c("alpha", "beta", "gamma", "delta")
  big_levels <- sprintf("e%04d", seq_len(300))
  rducks_register_scalar_udf(con, "e_small", function(x) x,
                             args = list(ENUM(small_levels)), returns = ENUM(small_levels))
  rducks_register_scalar_udf(con, "e_big", function(x) x,
                             args = list(ENUM(big_levels)), returns = ENUM(big_levels))

  # Nested containers, marshalled recursively. `nullable` is FALSE for ARRAY
  # because DuckDB cannot put a fixed-size array through a CASE expression; inner
  # element NULLs still exercise the child null path. Registered before the bump.
  nested_cases <- list(
    list(name = "n_list",   type = LIST(INTEGER), nullable = TRUE,
         expr = "[mod(i, 5)::INTEGER, i::INTEGER, NULL, (i + 1)::INTEGER]"),
    list(name = "n_lstr",   type = LIST(VARCHAR), nullable = TRUE,
         expr = "['a', NULL, ('v' || i)]"),
    list(name = "n_arr",    type = ARRAY(DOUBLE, 3), nullable = FALSE,
         expr = "[i * 1.0, i * 2.0, i * 0.5]::DOUBLE[3]"),
    list(name = "n_struct", type = STRUCT(a = INTEGER, b = VARCHAR), nullable = TRUE,
         expr = "{a: i::INTEGER, b: ('x' || i)}"),
    list(name = "n_slist",  type = STRUCT(id = INTEGER, tags = LIST(VARCHAR)), nullable = TRUE,
         expr = "{id: i::INTEGER, tags: ['a', ('t' || i)]}"),
    list(name = "n_llist",  type = LIST(LIST(INTEGER)), nullable = TRUE,
         expr = "[[i::INTEGER, NULL], [mod(i, 3)::INTEGER]]"),
    list(name = "n_astruct", type = ARRAY(STRUCT(x = INTEGER), 2), nullable = FALSE,
         expr = "[{x: i::INTEGER}, {x: mod(i, 4)::INTEGER}]::STRUCT(x INTEGER)[2]"),
    # Non-NULL struct row whose nested field is NULL: the field must survive the
    # round-trip rather than be dropped from the row.
    list(name = "n_snull",  type = STRUCT(a = LIST(INTEGER), b = VARCHAR), nullable = TRUE,
         expr = "{a: CASE WHEN mod(i, 3) = 0 THEN NULL ELSE [i::INTEGER, mod(i, 5)::INTEGER] END, b: ('x' || i)}"),
    list(name = "n_map",    type = MAP(INTEGER, VARCHAR), nullable = TRUE,
         expr = "MAP{i::INTEGER: ('v' || i), (i + 1)::INTEGER: 'w'}"),
    list(name = "n_lmap",   type = LIST(MAP(INTEGER, INTEGER)), nullable = TRUE,
         expr = "[MAP{i::INTEGER: mod(i, 9)::INTEGER}, MAP{(i + 1)::INTEGER: 0}]"),
    list(name = "n_mstruct", type = MAP(VARCHAR, STRUCT(a = INTEGER)), nullable = TRUE,
         expr = "MAP{('k' || i): {a: i::INTEGER}}")
  )
  for (case in nested_cases) {
    rducks_register_scalar_udf(con, case$name, function(x) x,
                               args = list(case$type), returns = case$type)
  }

  # GEOMETRY crosses the boundary as its opaque physical bytes (WKB for a real
  # geometry); the wire transports those bytes verbatim, so the test uses
  # arbitrary byte payloads rather than valid WKB. Core DuckDB SQL cannot produce
  # a GEOMETRY inline, so it is exercised by composing a maker (INTEGER ->
  # GEOMETRY, builds bytes in R) with an identity and an inspector (GEOMETRY ->
  # VARCHAR), covering geometry both as a wire result and a wire input.
  rducks_register_scalar_udf(con, "g_make", function(x) as.raw(c(x %% 256L, (x + 1L) %% 256L, 7L)),
                             args = list(INTEGER), returns = GEOMETRY)
  rducks_register_scalar_udf(con, "g_id", function(x) x, args = list(GEOMETRY), returns = GEOMETRY)
  rducks_register_scalar_udf(con, "g_show", function(x) paste(as.integer(x), collapse = ","),
                             args = list(GEOMETRY), returns = VARCHAR)

  # UNION cannot be projected to R by the DuckDB client on this build, so it is
  # exercised with an identity UDF and union_extract inside SQL. The maker is
  # registered under threads=1 with the others.
  rducks_register_scalar_udf(con, "u_id", function(x) x,
                             args = list(UNION(a = INTEGER, b = VARCHAR)),
                             returns = UNION(a = INTEGER, b = VARCHAR))

  # Bump DuckDB threads for concurrent off-main execution -> NNG worker roundtrip.
  rducks_set_execution_plan(con, plan, threads = 3L, external_threads = 2L)

  geom_mismatch <- DBI::dbGetQuery(con, paste0(
    "SELECT count(*) c FROM (SELECT i::INTEGER j FROM range(4000) t(i)) s ",
    "WHERE g_show(g_id(g_make(j))) <> (mod(j, 256) || ',' || mod(j + 1, 256) || ',7')"
  ))$c
  expect_equal(as.integer(geom_mismatch), 0L, info = "ipc roundtrip: geometry (maker/id/show)")

  # UNION roundtrip: alternating tags, plus an active-but-NULL member (tag 'a',
  # value NULL) which must keep its tag — the explicit-tag wire encoding has no
  # active-vs-inactive ambiguity. mod 3 == 2 selects the NULL-valued 'a' case.
  union_mismatch <- DBI::dbGetQuery(con, paste0(
    "SELECT count(*) c FROM (SELECT i::INTEGER j FROM range(4000) t(i)) s WHERE CASE ",
    "WHEN mod(j, 3) = 0 THEN union_extract(u_id(union_value(a := j)), 'a') IS DISTINCT FROM j ",
    "WHEN mod(j, 3) = 1 THEN union_extract(u_id(union_value(b := 'v' || j)), 'b') IS DISTINCT FROM ('v' || j) ",
    "ELSE union_extract(u_id(union_value(a := NULL::INTEGER)), 'a') IS DISTINCT FROM NULL::INTEGER ",
    "OR union_tag(u_id(union_value(a := NULL::INTEGER))) IS DISTINCT FROM 'a' END"
  ))$c
  expect_equal(as.integer(union_mismatch), 0L, info = "ipc roundtrip: union (tags + active-null member)")

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

  DBI::dbExecute(con, sprintf("CREATE TYPE rdk_mood AS ENUM (%s)",
                              paste0("'", small_levels, "'", collapse = ",")))
  DBI::dbExecute(con, sprintf("CREATE TYPE rdk_big AS ENUM (%s)",
                              paste0("'", big_levels, "'", collapse = ",")))
  enum_cases <- list(
    list(name = "e_small",
         expr = "((ARRAY['alpha','beta','gamma','delta'])[mod(i, 4) + 1]::rdk_mood)"),
    list(name = "e_big",
         expr = "(('e' || lpad((mod(i, 300) + 1)::VARCHAR, 4, '0'))::rdk_big)")
  )
  for (case in enum_cases) {
    valexpr <- sprintf("CASE WHEN mod(i, 7) = 0 THEN NULL ELSE %s END", case$expr)
    sql <- sprintf(
      "SELECT count(*) c FROM (SELECT %s v FROM range(4000) t(i)) s WHERE %s(v) IS DISTINCT FROM v",
      valexpr, case$name
    )
    mismatch <- DBI::dbGetQuery(con, sql)$c
    expect_equal(as.integer(mismatch), 0L, info = paste0("ipc roundtrip: ", case$name))
  }

  for (case in nested_cases) {
    valexpr <- if (isTRUE(case$nullable)) {
      sprintf("CASE WHEN mod(i, 7) = 0 THEN NULL ELSE %s END", case$expr)
    } else {
      case$expr
    }
    sql <- sprintf(
      "SELECT count(*) c FROM (SELECT %s v FROM range(4000) t(i)) s WHERE %s(v) IS DISTINCT FROM v",
      valexpr, case$name
    )
    mismatch <- DBI::dbGetQuery(con, sql)$c
    expect_equal(as.integer(mismatch), 0L, info = paste0("ipc roundtrip: ", case$name))
  }

  # Gated types must be rejected at registration under the ipc plan, not fail
  # later in a worker. The native bridge does not cover them yet. Reset to
  # single-thread first: registration requires single-thread mode, so without
  # this reset expect_error() could pass on the thread-state error instead of the
  # wire-support rejection. The error-text assertion pins the real reason.
  rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
  rejected <- list(
    list(name = "rej_variant",  type = VARIANT),
    list(name = "rej_list_var", type = LIST(VARIANT)),
    list(name = "rej_union_var", type = UNION(a = VARIANT))
  )
  for (case in rejected) {
    expect_error(
      rducks_register_scalar_udf(con, case$name, function(x) x,
                                 args = list(case$type), returns = case$type),
      pattern = "cannot use the Quack wire marshalling",
      info = paste0("ipc registration must reject: ", case$name)
    )
  }

  # Dynamic (omitted-args) UDFs are now supported on the wire: registration
  # succeeds and the concrete argument types resolve per call site at bind.
  # End-to-end coverage lives in test_ipc_dynamic_args.R.
  rducks_set_execution_plan(con, plan, threads = 1L, external_threads = 1L)
  expect_silent(
    rducks_register_scalar_udf(con, "accept_dynamic", function(...) 1L, returns = INTEGER)
  )
})
