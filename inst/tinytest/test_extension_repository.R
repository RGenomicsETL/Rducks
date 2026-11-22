library(Rducks)

min_version <- getFromNamespace("rducks_min_duckdb_version", "Rducks")
imports <- utils::packageDescription("Rducks", fields = "Imports")
expect_true(grepl(sprintf("duckdb \\(>= %s\\)", sub("^v", "", min_version)), imports))

local({
  config <- rducks_duckdb_config(list(threads = 1L, allow_extension_repositories = "forbidden"))
  expect_identical(config$threads, 1L)
  expect_identical(config$allow_extension_repositories, "forbidden")
  expect_true(startsWith(config$extension_repository_directory, tempdir()))
  expect_error(rducks_duckdb_config(list(1)), pattern = "named list")

  key <- readLines(system.file("rducks_extension", "build", "rducks.pub", package = "Rducks"))
  expect_true(length(key) == 1L && grepl("^[A-Za-z0-9+/]+=*$", key))
})

setting <- function(con, name) {
  DBI::dbGetQuery(con, sprintf("SELECT current_setting('%s') AS v", name))$v[[1L]]
}
rducks_function_count <- function(con) {
  DBI::dbGetQuery(con, "SELECT count(*) AS n FROM duckdb_functions() WHERE function_name LIKE 'rducks_%'")$n
}

# The signed extension loads with signature checks enabled and leaves no
# repository record behind.
local({
  con <- DBI::dbConnect(duckdb::duckdb(config = rducks_duckdb_config()))
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  expect_false(setting(con, "allow_unsigned_extensions"))
  extension_directory <- setting(con, "extension_directory")

  repositories <- function() {
    DBI::dbGetQuery(con, "SELECT repository_name FROM duckdb_extension_repositories()")$repository_name
  }
  builtin <- repositories()

  expect_silent(rducks_enable(con))
  expect_true(rducks_function_count(con) > 0)
  expect_identical(setting(con, "extension_directory"), extension_directory)
  expect_identical(repositories(), builtin)
  expect_identical(list.files(setting(con, "extension_repository_directory")), character())

  rducks_enable(con)
  expect_true(rducks_function_count(con) > 0)
})

# A connection without a startup repository directory needs home_registry.
local({
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  expect_error(rducks_enable(con), pattern = "home_registry = TRUE")
  expect_identical(rducks_function_count(con), 0)
  expect_error(rducks_enable(con, home_registry = NA), pattern = "TRUE or FALSE")
})

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = rducks_duckdb_config(list(
    allow_extension_repositories = "forbidden"
  ))))
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  expect_error(rducks_enable(con), pattern = "forbids extension repositories")
})

# A tampered copy fails DuckDB's signature check.
local({
  bundled <- rducks_extension_path()
  tampered <- file.path(tempfile("rducks-tampered-"), "rducks.duckdb_extension")
  dir.create(dirname(tampered))
  on.exit(unlink(dirname(tampered), recursive = TRUE), add = TRUE)
  bytes <- readBin(bundled, "raw", n = file.size(bundled))
  bytes[[1000L]] <- xor(bytes[[1000L]], as.raw(1L))
  writeBin(bytes, tampered)

  con <- DBI::dbConnect(duckdb::duckdb(config = rducks_duckdb_config()))
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  expect_error(rducks_enable(con, extension_path = tampered), pattern = "signature")
})
