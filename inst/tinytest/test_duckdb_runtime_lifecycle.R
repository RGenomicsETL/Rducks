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

    expect_true(exists(ref_key, envir = Rducks:::rducks_connection_ref_token_store(), inherits = FALSE))
    expect_true(exists(token, envir = Rducks:::rducks_connection_plan_store(), inherits = FALSE))
    expect_true(exists(token, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
    expect_equal(reg$spec$name, "rducks_lifecycle_plus_one")
    list(token = token, ref_key = ref_key)
  }

  keys <- make_connection_token()
  rducks_test_force_gc()

  expect_false(exists(keys$ref_key, envir = Rducks:::rducks_connection_ref_token_store(), inherits = FALSE))
  expect_false(exists(keys$token, envir = Rducks:::rducks_connection_plan_store(), inherits = FALSE))
  expect_false(exists(keys$token, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
})

local({
  drv <- duckdb::duckdb(config = list(allow_unsigned_extensions = "true"))
  con1 <- DBI::dbConnect(drv)
  con2 <- DBI::dbConnect(drv)

  rducks_enable(con1, threads = "single")
  rducks_enable(con2, threads = "single")
  token1 <- Rducks:::rducks_connection_key(con1)
  token2 <- Rducks:::rducks_connection_key(con2)

  expect_false(identical(token1, token2))
  rducks_set_execution_plan(con1, rducks_execution_plan("arrow_c", "serial"))
  expect_equal(rducks_current_execution_plan(con1)$plan_id, "arrow_c+serial")
  expect_equal(rducks_current_execution_plan(con2)$plan_id, "arrow_r+serial")

  invisible(rducks_register(con1, "rducks_lifecycle_con1", rducks_lifecycle_plus_one_fun, INTEGER, INTEGER))
  invisible(rducks_register(con2, "rducks_lifecycle_con2", rducks_lifecycle_times_two_fun, INTEGER, INTEGER))
  expect_true(exists(token1, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
  expect_true(exists(token2, envir = Rducks:::rducks_registration_store(), inherits = FALSE))

  DBI::dbDisconnect(con1, shutdown = TRUE)
  rm(con1)
  rducks_test_force_gc()

  expect_false(exists(token1, envir = Rducks:::rducks_connection_plan_store(), inherits = FALSE))
  expect_false(exists(token1, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
  expect_true(exists(token2, envir = Rducks:::rducks_connection_plan_store(), inherits = FALSE))
  expect_true(exists(token2, envir = Rducks:::rducks_registration_store(), inherits = FALSE))
  expect_equal(rducks_current_execution_plan(con2)$plan_id, "arrow_r+serial")

  DBI::dbDisconnect(con2, shutdown = TRUE)
})
