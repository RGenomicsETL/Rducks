library(Rducks)

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")

  reg1 <- rducks_register(con, "rducks_plus_one", function(x) x + 1, DOUBLE, DOUBLE)
  expect_inherits(reg1, "rducks_registration")
  expect_equal(reg1$spec$mode, "scalar")
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_plus_one(41.0) AS x")$x, 42)

  reg0 <- rducks_register(con, "rducks_hello", function() "hello from R", NULL, VARCHAR)
  expect_equal(reg0$spec$args, character())
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_hello() AS x")$x, "hello from R")

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
