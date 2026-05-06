library(Rducks)

local({
  old_dev <- Sys.getenv("RDUCKS_DEV_SURFACES", unset = NA_character_)
  Sys.unsetenv("RDUCKS_DEV_SURFACES")
  on.exit({
    if (is.na(old_dev)) Sys.unsetenv("RDUCKS_DEV_SURFACES") else Sys.setenv(RDUCKS_DEV_SURFACES = old_dev)
  }, add = TRUE)
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_thread_is_main(1::UBIGINT) AS ok"), "does not exist|not exist|Catalog Error")
  expect_error(DBI::dbGetQuery(con, "SELECT * FROM rducks_parallel_range(1::UBIGINT)"), "does not exist|not exist|Catalog Error")
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_set_execution_backend('single') AS ok"), "main-thread capability")
  expect_error(DBI::dbGetQuery(con, "SELECT rducks_set_main_thread_token('posix-pthread-ptr:1') AS ok"), "invalid Rducks main thread token")
})
Sys.setenv(RDUCKS_DEV_SURFACES = "true")

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  reg1 <- rducks_register(con, "rducks_plus_one", function(x) x + 1, DOUBLE, DOUBLE)
  expect_inherits(reg1, "rducks_registration")
  expect_equal(reg1$spec$mode, "scalar")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_plus_one(41.0) AS x")$x, 42)

  reg1b <- rducks_register(con, "rducks_plus_one", function(x) x + 2, DOUBLE, DOUBLE)
  expect_inherits(reg1b, "rducks_registration")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_plus_one(40.0) AS x")$x, 42)
  expect_equal(rducks_explain_udf(con, "rducks_plus_one")$returns, "f64")

  reg0 <- rducks_register(con, "rducks_hello", function() "hello from R", NULL, VARCHAR)
  expect_equal(reg0$spec$args, character())
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_hello() AS x")$x, "hello from R")

  expect_error(
    DBI::dbGetQuery(
      con,
      paste(
        "SELECT rducks_register_scalar(",
        "'bad_manual', 'not-a-valid-evaluator-id', 'not-a-valid-evaluator-token',",
        "'i32', 'i32', 'default', 'rethrow', FALSE, 'R') AS ok"
      )
    ),
    "invalid Rducks evaluator handle"
  )

  invisible(rducks_register(
    con,
    "rducks_gc_survives",
    local({
      offset <- 40L
      function() offset + 2L
    }),
    character(),
    INTEGER
  ))
  for (i in 1:3) invisible(gc())
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_gc_survives() AS x")$x, 42L)

  reg2 <- rducks_register(con, "rducks_add", function(x, y) x + y, c(DOUBLE, DOUBLE), DOUBLE)
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_add(1.5, 2.25) AS x")$x, 3.75)

  reg3 <- rducks_register(con, "rducks_i32_double", function(x) as.integer(x * 2L), "i32", "i32")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_i32_double(21::INTEGER) AS x")$x, 42L)

  reg4 <- rducks_register(con, "rducks_not", function(x) !x, "bool", "bool")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_not(TRUE) AS x")$x, FALSE)

  reg5 <- rducks_register(con, "rducks_greet", function(x) paste0('hi ', x), "varchar", "varchar")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_greet('duck') AS x")$x, "hi duck")
})
