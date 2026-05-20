library(Rducks)

rducks_test_force_gc <- function(n = 6L) {
  for (i in seq_len(n)) invisible(gc())
}

rducks_lifecycle_plus_one_fun <- function(x) x + 1L
environment(rducks_lifecycle_plus_one_fun) <- baseenv()
rducks_lifecycle_times_two_fun <- function(x) x * 2L
environment(rducks_lifecycle_times_two_fun) <- baseenv()

rducks_runtime_lifecycle_body <- function() {
  local({
    make_connection_token <- function() {
      con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
      rducks_enable(con, threads = "single")
      rducks_set_execution_plan(con, rducks_execution_plan("arrow_c", "serial"))
      reg <- rducks_register_scalar_udf(con, "rducks_lifecycle_plus_one", rducks_lifecycle_plus_one_fun, INTEGER, INTEGER)
      conn_ref <- Rducks:::rducks_connection_ref(con)
      ref_key <- Rducks:::rducks_connection_ref_key(conn_ref)
      token <- Rducks:::rducks_connection_key(con)
      db_token <- Rducks:::rducks_database_registration_key(con)

      expect_true(exists(ref_key, envir = Rducks:::rducks_connection_ref_token_store(), inherits = FALSE))
      expect_true(exists(token, envir = Rducks:::rducks_connection_plan_store(), inherits = FALSE))
      expect_false(exists(token, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
      expect_true(exists(db_token, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
      expect_equal(reg$spec$name, "rducks_lifecycle_plus_one")
      list(token = token, ref_key = ref_key, db_token = db_token)
    }

    keys <- make_connection_token()
    rducks_test_force_gc()

    expect_false(exists(keys$ref_key, envir = Rducks:::rducks_connection_ref_token_store(), inherits = FALSE))
    expect_false(exists(keys$token, envir = Rducks:::rducks_connection_plan_store(), inherits = FALSE))
    expect_false(exists(keys$token, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
    expect_false(exists(keys$db_token, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
  })

  local({
    drv <- duckdb::duckdb(config = list(allow_unsigned_extensions = "true"))
    con_enabled <- DBI::dbConnect(drv)
    con_plain <- DBI::dbConnect(drv)
    on.exit(DBI::dbDisconnect(con_enabled, shutdown = TRUE), add = TRUE)
    on.exit(DBI::dbDisconnect(con_plain, shutdown = TRUE), add = TRUE)

    rducks_enable(con_enabled, threads = "single")
    invisible(rducks_register_scalar_udf(con_enabled, "rducks_lifecycle_enabled_only", rducks_lifecycle_plus_one_fun, INTEGER, INTEGER))
    expect_equal(NROW(rducks_list_udfs(con_plain)), 0L)
    rducks_enable(con_plain, threads = "single")
    expect_true("rducks_lifecycle_enabled_only" %in% rducks_list_udfs(con_plain)$name)
    expect_equal(DBI::dbGetQuery(con_plain, "SELECT rducks_lifecycle_enabled_only(41::INTEGER) AS x")$x, 42L)
    invisible(rducks_register_scalar_udf(con_plain, "rducks_lifecycle_after_refresh", rducks_lifecycle_times_two_fun, INTEGER, INTEGER))
    expect_equal(DBI::dbGetQuery(con_plain, "SELECT rducks_lifecycle_after_refresh(21::INTEGER) AS x")$x, 42L)
  })

  local({
    drv <- duckdb::duckdb(config = list(allow_unsigned_extensions = "true"))
    con1 <- DBI::dbConnect(drv)
    con2 <- DBI::dbConnect(drv)

    rducks_enable(con1, threads = "single")
    rducks_enable(con2, threads = "single")
    runtime_stats <- rducks_runtime_stats(con1)
    expect_equal(names(runtime_stats), c(
      "registry_entries", "active_entries", "stale_entries", "entries_created",
      "stale_aliases", "connections_opened", "connections_closed",
      "connections_current", "connection_open_failed", "queue_init_failed",
      "native_release_supported"
    ))
    expect_true(runtime_stats$registry_entries[[1L]] >= 1)
    expect_true(runtime_stats$active_entries[[1L]] >= 1)
    expect_equal(runtime_stats$registry_entries[[1L]], runtime_stats$active_entries[[1L]] + runtime_stats$stale_entries[[1L]])
    expect_true(runtime_stats$entries_created[[1L]] >= runtime_stats$active_entries[[1L]])
    expect_true(runtime_stats$connections_opened[[1L]] >= runtime_stats$connections_closed[[1L]])
    expect_equal(runtime_stats$connections_current[[1L]], runtime_stats$connections_opened[[1L]] - runtime_stats$connections_closed[[1L]])
    expect_false(runtime_stats$native_release_supported[[1L]])
    expect_error(DBI::dbGetQuery(con1, "SELECT rducks_runtime_registry_capacity()"), "function|Function|Catalog")
    expect_error(DBI::dbGetQuery(con1, "SELECT rducks_runtime_connections_current()"), "function|Function|Catalog")
    expect_error(DBI::dbGetQuery(con1, "SELECT rducks_runtime_native_release_supported()"), "function|Function|Catalog")
    expect_true(all(unlist(runtime_stats[1, setdiff(names(runtime_stats), "native_release_supported")], use.names = FALSE) >= 0))
    release_stats <- rducks_release_stats(con1)
    expect_equal(names(release_stats), c("queued", "released", "failed", "pending"))
    expect_true(all(unlist(release_stats[1, ], use.names = FALSE) >= 0))
    token1 <- Rducks:::rducks_connection_key(con1)
    token2 <- Rducks:::rducks_connection_key(con2)
    db_token1 <- Rducks:::rducks_database_registration_key(con1)
    db_token2 <- Rducks:::rducks_database_registration_key(con2)

    expect_false(identical(token1, token2))
    expect_identical(db_token1, db_token2)
    rducks_set_execution_plan(con1, rducks_execution_plan("arrow_c", "serial"))
    expect_equal(rducks_current_execution_plan(con1)$plan_id, "arrow_c+serial")
    expect_equal(rducks_current_execution_plan(con2)$plan_id, "arrow_r+serial")

    invisible(rducks_register_scalar_udf(con1, "rducks_lifecycle_con1", rducks_lifecycle_plus_one_fun, INTEGER, INTEGER))
    invisible(rducks_register_scalar_udf(con2, "rducks_lifecycle_con2", rducks_lifecycle_times_two_fun, INTEGER, INTEGER))
    expect_false(exists(token1, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
    expect_false(exists(token2, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
    expect_true(exists(db_token1, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
    expect_equal(sort(rducks_list_udfs(con2)$name), c("rducks_lifecycle_con1", "rducks_lifecycle_con2"))

    rducks_release(con1)
    rducks_release(con1)
    expect_false(exists(token1, envir = Rducks:::rducks_connection_plan_store(), inherits = FALSE))
    expect_false(exists(token1, envir = Rducks:::rducks_connection_runtime_token_store(), inherits = FALSE))
    expect_true(exists(db_token1, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
    expect_equal(DBI::dbGetQuery(con2, "SELECT rducks_lifecycle_con1(41::INTEGER) AS x")$x, 42L)

    DBI::dbDisconnect(con1)
    rm(con1)
    rducks_test_force_gc()

    expect_false(exists(token1, envir = Rducks:::rducks_connection_plan_store(), inherits = FALSE))
    expect_false(exists(token1, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
    expect_true(exists(token2, envir = Rducks:::rducks_connection_plan_store(), inherits = FALSE))
    expect_false(exists(token2, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
    expect_true(exists(db_token2, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
    expect_equal(rducks_current_execution_plan(con2)$plan_id, "arrow_r+serial")
    expect_equal(DBI::dbGetQuery(con2, "SELECT rducks_lifecycle_con1(41::INTEGER) AS x")$x, 42L)

    rducks_release(con2)
    rducks_release(con2)
    expect_false(exists(db_token2, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
    expect_equal(DBI::dbGetQuery(con2, "SELECT rducks_lifecycle_con2(21::INTEGER) AS x")$x, 42L)
    detached_explain <- rducks_explain_udf(con2, "rducks_lifecycle_con2")
    expect_false(detached_explain$r_side_record[[1L]])
    expect_equal(detached_explain$name[[1L]], "rducks_lifecycle_con2")

    DBI::dbDisconnect(con2, shutdown = TRUE)
  })

  local({
    main_path <- tempfile(fileext = ".duckdb")
    aux_path <- tempfile(fileext = ".duckdb")
    on.exit(unlink(c(main_path, aux_path, paste0(main_path, ".wal"), paste0(aux_path, ".wal")), force = TRUE), add = TRUE)

    aux_con <- DBI::dbConnect(duckdb::duckdb(dbdir = aux_path, config = list(allow_unsigned_extensions = "true")))
    DBI::dbExecute(aux_con, "CREATE TABLE some_table(i INTEGER)")
    DBI::dbExecute(aux_con, "INSERT INTO some_table VALUES (1), (41)")
    DBI::dbDisconnect(aux_con, shutdown = TRUE)

    main_con <- DBI::dbConnect(duckdb::duckdb(dbdir = main_path, config = list(allow_unsigned_extensions = "true")))
    on.exit(DBI::dbDisconnect(main_con, shutdown = TRUE), add = TRUE)
    rducks_enable(main_con, threads = "single")
    invisible(rducks_register_scalar_udf(
      main_con, "rducks_lifecycle_attach_plus", rducks_lifecycle_plus_one_fun, INTEGER, INTEGER
    ))
    DBI::dbExecute(main_con, sprintf("ATTACH %s AS aux", DBI::dbQuoteString(main_con, aux_path)))
    attached <- DBI::dbGetQuery(
      main_con,
      "SELECT rducks_lifecycle_attach_plus(i) AS x FROM aux.some_table ORDER BY i"
    )
    expect_equal(attached$x, c(2L, 42L))
    DBI::dbExecute(main_con, "DETACH aux")
  })

  local({
    path_a <- tempfile(fileext = ".duckdb")
    path_b <- tempfile(fileext = ".duckdb")
    on.exit(unlink(c(path_a, path_b, paste0(path_a, ".wal"), paste0(path_b, ".wal")), force = TRUE), add = TRUE)

    con_a <- DBI::dbConnect(duckdb::duckdb(dbdir = path_a, config = list(allow_unsigned_extensions = "true")))
    con_b <- DBI::dbConnect(duckdb::duckdb(dbdir = path_b, config = list(allow_unsigned_extensions = "true")))
    on.exit(DBI::dbDisconnect(con_a, shutdown = TRUE), add = TRUE)
    on.exit(DBI::dbDisconnect(con_b, shutdown = TRUE), add = TRUE)

    rducks_enable(con_a, threads = "single")
    rducks_enable(con_b, threads = "single")
    token_a <- Rducks:::rducks_database_registration_key(con_a)
    token_b <- Rducks:::rducks_database_registration_key(con_b)
    expect_false(identical(token_a, token_b))

    invisible(rducks_register_scalar_udf(con_a, "rducks_lifecycle_same_name", rducks_lifecycle_plus_one_fun, INTEGER, INTEGER))
    invisible(rducks_register_scalar_udf(con_b, "rducks_lifecycle_same_name", rducks_lifecycle_times_two_fun, INTEGER, INTEGER))
    expect_equal(DBI::dbGetQuery(con_a, "SELECT rducks_lifecycle_same_name(41::INTEGER) AS x")$x, 42L)
    expect_equal(DBI::dbGetQuery(con_b, "SELECT rducks_lifecycle_same_name(41::INTEGER) AS x")$x, 82L)

    rducks_release(con_a)
    expect_false(exists(token_a, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
    expect_true(exists(token_b, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
    expect_equal(DBI::dbGetQuery(con_b, "SELECT rducks_lifecycle_same_name(21::INTEGER) AS x")$x, 42L)
  })

  local({
    seen_tokens <- character()
    seen_db_tokens <- character()
    for (i in seq_len(3L)) {
      con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
      rducks_enable(con, threads = "single")
      rducks_set_execution_plan(con, rducks_execution_plan("arrow_c", "serial"))
      name <- paste0("rducks_lifecycle_loop_", i)
      invisible(rducks_register_scalar_udf(con, name, rducks_lifecycle_plus_one_fun, INTEGER, INTEGER))
      expect_equal(DBI::dbGetQuery(con, sprintf("SELECT %s(41::INTEGER) AS x", name))$x, 42L)

      token <- Rducks:::rducks_connection_key(con)
      db_token <- Rducks:::rducks_database_registration_key(con)
      expect_true(exists(token, envir = Rducks:::rducks_connection_plan_store(), inherits = FALSE))
      expect_true(exists(db_token, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
      seen_tokens <- c(seen_tokens, token)
      seen_db_tokens <- c(seen_db_tokens, db_token)

      rducks_release(con)
      expect_false(exists(token, envir = Rducks:::rducks_connection_plan_store(), inherits = FALSE))
      expect_false(exists(db_token, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
      expect_equal(DBI::dbGetQuery(con, sprintf("SELECT %s(1::INTEGER) AS x", name))$x, 2L)
      DBI::dbDisconnect(con, shutdown = TRUE)
      rm(con)
      rducks_test_force_gc()
    }
    expect_equal(length(unique(seen_tokens)), length(seen_tokens))
    expect_equal(length(unique(seen_db_tokens)), length(seen_db_tokens))
    for (token in seen_tokens) {
      expect_false(exists(token, envir = Rducks:::rducks_connection_plan_store(), inherits = FALSE))
      expect_false(exists(token, envir = Rducks:::rducks_connection_runtime_token_store(), inherits = FALSE))
    }
    for (db_token in seen_db_tokens) {
      expect_false(exists(db_token, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
    }
  })
}

rducks_runtime_lifecycle_body()
