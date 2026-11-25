library(Rducks)

min_version <- getFromNamespace("rducks_min_duckdb_version", "Rducks")
load_from_repository <- getFromNamespace("rducks_load_from_repository", "Rducks")
version_dir <- getFromNamespace("rducks_repository_version_dir", "Rducks")
imports <- utils::packageDescription("Rducks", fields = "Imports")
expect_true(grepl(sprintf("duckdb \\(>= %s\\)", sub("^v", "", min_version)), imports))

# DuckDB's GetVersionDirectoryName(): releases are versions without "-dev".
expect_identical(version_dir("v2.0.0", "abc123"), "v2.0.0")
expect_identical(version_dir("2.1.0-rc1", "abc123"), "v2.1.0-rc1")
expect_identical(version_dir("v2.1.0-dev42", "abc123"), "abc123")

local({
  config <- rducks_duckdb_config(list(threads = 1L, allow_extension_repositories = "forbidden"))
  expect_identical(config$threads, 1L)
  expect_identical(config$allow_extension_repositories, "forbidden")
  expect_true(startsWith(config$extension_repository_directory, tempdir()))
  expect_error(rducks_duckdb_config(list(1)), pattern = "named list")

  key <- readLines(system.file("rducks_extension", "build", "rducks.pub", package = "Rducks"))
  expect_true(length(key) == 1L && grepl("^[A-Za-z0-9+/]+=*$", key))
})

connect <- function(config = rducks_duckdb_config()) {
  DBI::dbConnect(duckdb::duckdb(config = config, shared_home = FALSE))
}
setting <- function(con, name) {
  DBI::dbGetQuery(con, sprintf("SELECT current_setting('%s') AS v", name))$v[[1L]]
}
rducks_function_count <- function(con) {
  DBI::dbGetQuery(con, "SELECT count(*) AS n FROM duckdb_functions() WHERE function_name LIKE 'rducks_%'")$n
}
repositories <- function(con) {
  DBI::dbGetQuery(con, "SELECT repository_name FROM duckdb_extension_repositories()")$repository_name
}
staged <- function() {
  list.files(file.path(tempdir(), "rducks"), pattern = "^repository-")
}

# The signed extension loads with signature checks enabled and leaves no
# repository record or staged copy behind.
local({
  con <- connect()
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  expect_false(setting(con, "allow_unsigned_extensions"))
  extension_directory <- setting(con, "extension_directory")
  builtin <- repositories(con)

  expect_silent(rducks_enable(con))
  expect_true(rducks_function_count(con) > 0)
  expect_identical(setting(con, "extension_directory"), extension_directory)
  expect_identical(repositories(con), builtin)
  expect_identical(list.files(setting(con, "extension_repository_directory")), character())
  expect_identical(staged(), character())

  rducks_enable(con)
  expect_true(rducks_function_count(con) > 0)
})

# A connection that keeps DuckDB's default access is moved to 'allowed'. The
# default is 'undecided' in DuckDB 2.0.0 and 'hosts' from 2.0.1.
local({
  con <- connect(list(extension_repository_directory = tempfile("rducks-registry-")))
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  expect_true(setting(con, "allow_extension_repositories") %in% c("undecided", "hosts"))
  rducks_enable(con)
  expect_identical(setting(con, "allow_extension_repositories"), "allowed")
  expect_true(rducks_function_count(con) > 0)
})

# A connection without a startup repository directory needs home_registry.
local({
  con <- connect(list())
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  expect_error(rducks_enable(con), pattern = "home_registry = TRUE")
  expect_identical(rducks_function_count(con), 0)
  expect_error(rducks_enable(con, home_registry = NA), pattern = "TRUE or FALSE")
})

local({
  con <- connect(rducks_duckdb_config(list(allow_extension_repositories = "forbidden")))
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  expect_error(rducks_enable(con), pattern = "allow_extension_repositories = 'forbidden'")
})

# 'hosts_only' exists from DuckDB 2.0.1 and cannot be widened to 'allowed'.
if (utils::packageVersion("duckdb") >= "2.0.1") local({
  con <- connect(rducks_duckdb_config(list(allow_extension_repositories = "hosts_only")))
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  expect_error(rducks_enable(con), pattern = "allow_extension_repositories = 'hosts_only'")
  expect_identical(rducks_function_count(con), 0)
})

# Signature checks: through the repository, a copy of the bundled file loads
# and a copy with one changed byte does not. A plain LOAD of the bundled file
# fails because DuckDB does not trust the installation key outside the
# repository.
local({
  bundled <- rducks_extension_path()
  dir <- tempfile("rducks-signature-")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  good <- file.path(dir, "good.duckdb_extension")
  tampered <- file.path(dir, "tampered.duckdb_extension")
  bytes <- readBin(bundled, "raw", n = file.size(bundled))
  writeBin(bytes, good)
  bytes[[1000L]] <- xor(bytes[[1000L]], as.raw(1L))
  writeBin(bytes, tampered)

  con <- connect()
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  expect_error(load_from_repository(con, tampered, FALSE), pattern = "signature")
  expect_identical(rducks_function_count(con), 0)
  expect_error(rducks_enable(con, extension_path = bundled), pattern = "signature")
  expect_true(load_from_repository(con, good, FALSE))
  expect_true(rducks_function_count(con) > 0)
  expect_identical(staged(), character())
})
