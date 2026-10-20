library(Rducks)

local({
  if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE)) {
    exit_file("duckdb/DBI not available")
  }
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  on.exit(rducks_release(con), add = TRUE)

  rducks_register_scalar_udf(con, "rducks_direct_plus1", function(x) x + 1L,
    args = list(INTEGER), returns = INTEGER)
  expect_equal(DBI::dbGetQuery(con, "SELECT rducks_direct_plus1(41::INTEGER) AS x")$x, 42L)
})

# Vectorized BLOB/GEOMETRY results take the C fast path: one raw vector (or NULL)
# per row, validated as a whole list rather than through the per-row return
# check. A classed list (for example wk_wkb) must be accepted as-is, NULL
# elements must become SQL NULL, and a non-raw element must fail loudly.
local({
  if (!requireNamespace("duckdb", quietly = TRUE) || !requireNamespace("DBI", quietly = TRUE)) {
    exit_file("duckdb/DBI not available")
  }
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rducks_enable(con, threads = "single")
  on.exit(rducks_release(con), add = TRUE)

  wkb_point <- function(x, y) {
    c(as.raw(1L), as.raw(c(1L, 0L, 0L, 0L)),
      writeBin(c(x, y), raw(), size = 8L, endian = "little"))
  }
  rducks_register_scalar_udf(con, "rducks_vec_point_blob",
    function(x, y) {
      out <- lapply(seq_along(x), function(i) if (is.na(x[[i]])) NULL else wkb_point(x[[i]], y[[i]]))
      structure(out, class = "some_classed_list")
    },
    args = list(DOUBLE, DOUBLE), returns = BLOB, mode = "vectorized", null_handling = "special")
  res <- DBI::dbGetQuery(con, "
    SELECT i, rducks_vec_point_blob(CASE WHEN i = 2 THEN NULL ELSE i * 1.0 END, i * 2.0) AS b
    FROM range(4) t(i) ORDER BY i")
  expect_equal(nrow(res), 4L)
  expect_true(is.null(res$b[[3L]]) || all(is.na(res$b[[3L]])))
  expect_equal(res$b[[1L]], wkb_point(0, 0))
  expect_equal(res$b[[4L]], wkb_point(3, 6))

  rducks_register_scalar_udf(con, "rducks_vec_point_geom",
    function(x, y) lapply(seq_along(x), function(i) wkb_point(x[[i]], y[[i]])),
    args = list(DOUBLE, DOUBLE), returns = GEOMETRY, mode = "vectorized")
  same <- DBI::dbGetQuery(con, "
    SELECT bool_and(rducks_vec_point_geom(i * 1.0, i * 2.0) = ('POINT(' || i || ' ' || (2 * i) || ')')::GEOMETRY) AS ok
    FROM range(5) t(i)")$ok
  expect_true(isTRUE(same))

  rducks_register_scalar_udf(con, "rducks_vec_blob_bad_elt",
    function(x) as.list(x),
    args = list(DOUBLE), returns = BLOB, mode = "vectorized")
  expect_error(
    DBI::dbGetQuery(con, "SELECT rducks_vec_blob_bad_elt(i * 1.0) FROM range(3) t(i)"),
    pattern = "not compatible with BLOB|vectorized R function or marshal error")

  rducks_register_scalar_udf(con, "rducks_vec_blob_bad_len",
    function(x) list(as.raw(1L)),
    args = list(DOUBLE), returns = BLOB, mode = "vectorized")
  expect_error(
    DBI::dbGetQuery(con, "SELECT rducks_vec_blob_bad_len(i * 1.0) FROM range(3) t(i)"),
    pattern = "must have length|vectorized R function or marshal error")
})
