library(Rducks)

rducks_test_force_gc <- function(n = 6L) {
  for (i in seq_len(n)) invisible(gc())
}

rducks_lifecycle_plus_one_fun <- function(x) x + 1L
environment(rducks_lifecycle_plus_one_fun) <- baseenv()
rducks_lifecycle_times_two_fun <- function(x) x * 2L
environment(rducks_lifecycle_times_two_fun) <- baseenv()

local({
  make_connection_token <- function() {
    con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
    rducks_enable(con, threads = "single")
    rducks_set_execution_plan(con, rducks_execution_plan("arrow_c", "serial"))
    reg <- rducks_register(con, "rducks_lifecycle_plus_one", rducks_lifecycle_plus_one_fun, INTEGER, INTEGER)
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
  invisible(rducks_register(con_enabled, "rducks_lifecycle_enabled_only", rducks_lifecycle_plus_one_fun, INTEGER, INTEGER))
  expect_equal(NROW(rducks_list_udfs(con_plain)), 0L)
  rducks_enable(con_plain, threads = "single")
  expect_true("rducks_lifecycle_enabled_only" %in% rducks_list_udfs(con_plain)$name)
})

local({
  drv <- duckdb::duckdb(config = list(allow_unsigned_extensions = "true"))
  con1 <- DBI::dbConnect(drv)
  con2 <- DBI::dbConnect(drv)

  rducks_enable(con1, threads = "single")
  rducks_enable(con2, threads = "single")
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

  invisible(rducks_register(con1, "rducks_lifecycle_con1", rducks_lifecycle_plus_one_fun, INTEGER, INTEGER))
  invisible(rducks_register(con2, "rducks_lifecycle_con2", rducks_lifecycle_times_two_fun, INTEGER, INTEGER))
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

  DBI::dbDisconnect(con2, shutdown = TRUE)
})
