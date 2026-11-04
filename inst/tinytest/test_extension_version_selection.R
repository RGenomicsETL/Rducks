library(Rducks)

local({
  current <- getFromNamespace("rducks_installed_duckdb_version", "Rducks")()
  path <- rducks_extension_path()
  build_root <- dirname(dirname(path))
  bundled <- getFromNamespace("rducks_bundled_duckdb_versions", "Rducks")(build_root)

  expect_true(file.exists(path))
  expect_identical(basename(dirname(path)), current)
  selected <- trimws(Sys.getenv("RDUCKS_DUCKDB_VERSIONS", unset = ""))
  expected <- if (nzchar(selected)) {
    strsplit(selected, "\\s+")[[1L]]
  } else {
    c(paste0("v1.5.", 0:6), "v2.0.0")
  }
  expect_identical(bundled, expected)

  # DuckDB 2 reads C_STRUCT_UNSTABLE as the V2 C API, so engines from 2.0 on
  # get the stable V1 struct pinned to C API v1.5.6. The footer's last 512
  # bytes hold eight 32-byte fields (written in reverse) before the signature.
  footer_fields <- function(file) {
    size <- file.info(file)$size
    con <- file(file, "rb")
    on.exit(close(con))
    seek(con, size - 512)
    bytes <- readBin(con, "raw", 256L)
    fields <- vapply(seq_len(8L), function(i) {
      field <- bytes[(32L * (i - 1L) + 1L):(32L * i)]
      rawToChar(field[field != as.raw(0L)])
    }, character(1L))
    rev(fields)
  }
  for (version in bundled) {
    fields <- footer_fields(file.path(build_root, version, "rducks.duckdb_extension"))
    major <- as.integer(sub("^v([0-9]+)\\..*$", "\\1", version))
    expect_identical(fields[[1L]], "4", info = version)
    if (major < 2L) {
      expect_identical(fields[[5L]], "C_STRUCT_UNSTABLE", info = version)
      expect_identical(fields[[3L]], version, info = version)
    } else {
      expect_identical(fields[[5L]], "C_STRUCT", info = version)
      expect_identical(fields[[3L]], "v1.5.6", info = version)
    }
  }
  expect_identical(rducks_extension_path(current), path)
  expect_identical(rducks_extension_path(sub("^v", "", current)), path)
  expect_error(
    rducks_extension_path("v0.0.0"),
    pattern = "no bundled extension for DuckDB v0.0.0"
  )
  expect_error(
    rducks_extension_path("1.5.4.1"),
    pattern = "must be an exact release"
  )

  con <- duckdb::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  connection_version <- getFromNamespace(
    "rducks_connection_duckdb_version",
    "Rducks"
  )(con)
  expect_identical(connection_version, current)
})
