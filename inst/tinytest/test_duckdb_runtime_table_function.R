library(Rducks)

local({
  con <- DBI::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")), dbdir = ":memory:")
  on.exit({
    try(rducks_release(con), silent = TRUE)
    DBI::dbDisconnect(con, shutdown = TRUE)
  }, add = TRUE)
  rducks_enable(con, threads = "single")

  reg <- rducks_register_table(
    con,
    "rducks_table_basic",
    function() data.frame(i = 1:3, label = c("a", "b", "c")),
    chunk_size = 2L
  )
  expect_true(inherits(reg, "rducks_table_registration"))
  expect_equal(reg$spec$parameter_count, 0L)
  expect_equal(reg$spec$chunk_size, 2L)
  release_before <- rducks_release_stats(con)$released[[1L]]
  out <- DBI::dbGetQuery(con, "SELECT * FROM rducks_table_basic() ORDER BY i")
  expect_equal(out$i, 1:3)
  expect_equal(out$label, c("a", "b", "c"))
  release_after <- rducks_release_stats(con)$released[[1L]]
  expect_true(release_after >= release_before + 1)

  invisible(rducks_register_table(
    con,
    "rducks_table_multichunk",
    function() data.frame(i = 1:5),
    chunk_size = 2L
  ))
  multi <- DBI::dbGetQuery(con, "SELECT * FROM rducks_table_multichunk() ORDER BY i")
  expect_equal(multi$i, 1:5)

  projection_calls <- 0L
  invisible(rducks_register_table(
    con,
    "rducks_table_projection",
    function() {
      projection_calls <<- projection_calls + 1L
      data.frame(i = 1:5, keep = letters[1:5], expensive = paste0("x", 1:5))
    },
    chunk_size = 2L
  ))
  projected <- DBI::dbGetQuery(con, "SELECT keep FROM rducks_table_projection() WHERE i <= 3 ORDER BY keep")
  expect_equal(projected$keep, letters[1:3])
  counted <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM rducks_table_projection()")
  expect_equal(as.integer(counted$n), 5L)
  expect_true(projection_calls >= 2L)

  invisible(rducks_register_table(
    con,
    "rducks_table_empty",
    function() data.frame(i = integer(), label = character()),
    chunk_size = 2L
  ))
  empty <- DBI::dbGetQuery(con, "SELECT * FROM rducks_table_empty()")
  expect_equal(nrow(empty), 0L)
  expect_equal(names(empty), c("i", "label"))

  stream_next_calls <- 0L
  stream_close_calls <- 0L
  invisible(rducks_register_table(
    con,
    "rducks_table_streaming",
    function() {
      batch_index <- 0L
      batches <- list(
        data.frame(i = 1:2, label = c("a", "b"), ignored = 10:11),
        data.frame(i = 3:5, label = c("c", "d", "e"), ignored = 12:14)
      )
      rducks_table_stream(
        prototype = data.frame(i = integer(), label = character(), ignored = integer()),
        cardinality = 5,
        exact = TRUE,
        next_batch = function(n) {
          stream_next_calls <<- stream_next_calls + 1L
          batch_index <<- batch_index + 1L
          if (batch_index > length(batches)) return(NULL)
          batches[[batch_index]]
        },
        close = function() {
          stream_close_calls <<- stream_close_calls + 1L
        }
      )
    },
    chunk_size = 2L
  ))
  streamed <- DBI::dbGetQuery(con, "SELECT label FROM rducks_table_streaming() WHERE i >= 2 ORDER BY label")
  expect_equal(streamed$label, c("b", "c", "d", "e"))
  expect_true(stream_next_calls >= 3L)
  expect_equal(stream_close_calls, 1L)

  cardinality_probe <- rducks_table_stream(
    prototype = data.frame(i = integer()),
    next_batch = function(n) NULL,
    cardinality = 7,
    exact = TRUE
  )
  expect_equal(
    Rducks:::rducks_table_stream_cardinality(cardinality_probe),
    list(known = TRUE, rows = 7, exact = TRUE)
  )
  expect_error(
    rducks_table_stream(data.frame(i = integer()), function(n) NULL, cardinality = 1.5),
    "cardinality"
  )

  stream_count_close_calls <- 0L
  invisible(rducks_register_table(
    con,
    "rducks_table_streaming_count",
    function() {
      batch_index <- 0L
      rducks_table_stream(
        prototype = data.frame(i = integer(), ignored = integer()),
        next_batch = function(n) {
          batch_index <<- batch_index + 1L
          if (batch_index == 1L) data.frame(i = 1:3, ignored = 11:13) else NULL
        },
        close = function() {
          stream_count_close_calls <<- stream_count_close_calls + 1L
        }
      )
    },
    chunk_size = 2L
  ))
  stream_counted <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM rducks_table_streaming_count()")
  expect_equal(as.integer(stream_counted$n), 3L)
  expect_equal(stream_count_close_calls, 1L)

  stream_limit_close_calls <- 0L
  invisible(rducks_register_table(
    con,
    "rducks_table_streaming_limit_close",
    function() {
      batch_index <- 0L
      rducks_table_stream(
        prototype = data.frame(i = integer()),
        next_batch = function(n) {
          batch_index <<- batch_index + 1L
          if (batch_index > 3L) return(NULL)
          data.frame(i = seq_len(as.integer(n)) + (batch_index - 1L) * as.integer(n))
        },
        close = function() {
          stream_limit_close_calls <<- stream_limit_close_calls + 1L
        }
      )
    },
    chunk_size = 2L
  ))
  stream_limited <- DBI::dbGetQuery(con, "SELECT * FROM rducks_table_streaming_limit_close() LIMIT 1")
  expect_equal(stream_limited$i, 1L)
  invisible(gc())
  expect_equal(stream_limit_close_calls, 1L)

  invisible(rducks_register_table(
    con,
    "rducks_table_streaming_type_mismatch",
    function() {
      batch_index <- 0L
      rducks_table_stream(
        prototype = data.frame(i = integer()),
        next_batch = function(n) {
          batch_index <<- batch_index + 1L
          if (batch_index == 1L) data.frame(i = c(1.5, 2.5)) else NULL
        }
      )
    },
    chunk_size = 2L
  ))
  expect_error(
    DBI::dbGetQuery(con, "SELECT * FROM rducks_table_streaming_type_mismatch()"),
    "prototype type"
  )

  invisible(rducks_register_table(
    con,
    "rducks_table_streaming_exact_underflow",
    function() {
      batch_index <- 0L
      rducks_table_stream(
        prototype = data.frame(i = integer()),
        cardinality = 3,
        exact = TRUE,
        next_batch = function(n) {
          batch_index <<- batch_index + 1L
          if (batch_index == 1L) data.frame(i = 1:2) else NULL
        }
      )
    },
    chunk_size = 2L
  ))
  expect_error(
    DBI::dbGetQuery(con, "SELECT * FROM rducks_table_streaming_exact_underflow()"),
    "different row count"
  )

  invisible(rducks_register_table(
    con,
    "rducks_table_streaming_exact_overflow",
    function() {
      rducks_table_stream(
        prototype = data.frame(i = integer()),
        cardinality = 2,
        exact = TRUE,
        next_batch = function(n) data.frame(i = 1:3)
      )
    },
    chunk_size = 2L
  ))
  expect_error(
    DBI::dbGetQuery(con, "SELECT * FROM rducks_table_streaming_exact_overflow()"),
    "more rows|different row count"
  )

  invisible(rducks_register_table(
    con,
    "rducks_table_nulls",
    function() data.frame(i = c(1L, NA_integer_), x = c(1.5, NA_real_), ok = c(TRUE, NA), s = c("a", NA_character_)),
    chunk_size = 2L
  ))
  nulls <- DBI::dbGetQuery(con, "SELECT * FROM rducks_table_nulls() ORDER BY i NULLS LAST")
  expect_equal(nulls$i, c(1L, NA_integer_))
  expect_equal(nulls$x, c(1.5, NA_real_))
  expect_equal(nulls$ok, c(TRUE, NA))
  expect_equal(nulls$s, c("a", NA_character_))

  invisible(rducks_register_table(
    con,
    "rducks_table_named_list",
    function() list(i = 1:2, label = c("x", "y")),
    chunk_size = 2L
  ))
  named_list <- DBI::dbGetQuery(con, "SELECT * FROM rducks_table_named_list() ORDER BY i")
  expect_equal(named_list$i, 1:2)
  expect_equal(named_list$label, c("x", "y"))

  reg_args <- rducks_register_table(
    con,
    "rducks_table_args",
    function(n, prefix, keep) data.frame(i = seq_len(n), label = paste0(prefix, seq_len(n)), keep = keep),
    chunk_size = 2L
  )
  expect_equal(reg_args$spec$parameter_count, 3L)
  args_out <- DBI::dbGetQuery(con, "SELECT * FROM rducks_table_args(3, 'row', TRUE) ORDER BY i")
  expect_equal(args_out$i, 1:3)
  expect_equal(args_out$label, paste0("row", 1:3))
  expect_equal(args_out$keep, rep(TRUE, 3L))

  invisible(rducks_register_table(
    con,
    "rducks_table_bigint_args",
    function(big, ubig, literal) {
      data.frame(
        big = as.character(big),
        ubig = as.character(ubig),
        literal = as.character(literal),
        big_class = inherits(big, "rducks_bigint"),
        ubig_class = inherits(ubig, "rducks_ubigint"),
        literal_class = inherits(literal, "rducks_bigint")
      )
    },
    chunk_size = 2L
  ))
  bigint_args <- DBI::dbGetQuery(
    con,
    paste0(
      "SELECT * FROM rducks_table_bigint_args(",
      "9223372036854775806::BIGINT, ",
      "18446744073709551614::UBIGINT, ",
      "9223372036854775806)"
    )
  )
  expect_equal(bigint_args$big[[1L]], "9223372036854775806")
  expect_equal(bigint_args$ubig[[1L]], "18446744073709551614")
  expect_equal(bigint_args$literal[[1L]], "9223372036854775806")
  expect_true(isTRUE(bigint_args$big_class[[1L]]))
  expect_true(isTRUE(bigint_args$ubig_class[[1L]]))
  expect_true(isTRUE(bigint_args$literal_class[[1L]]))

  invisible(rducks_register_table(
    con,
    "rducks_table_dynamic_args",
    function(kind) {
      if (identical(kind, "numbers")) data.frame(i = 1:2) else data.frame(label = c("a", "b"))
    },
    chunk_size = 2L
  ))
  dyn_numbers <- DBI::dbGetQuery(con, "SELECT * FROM rducks_table_dynamic_args('numbers') ORDER BY i")
  expect_equal(names(dyn_numbers), "i")
  expect_equal(dyn_numbers$i, 1:2)
  dyn_labels <- DBI::dbGetQuery(con, "SELECT * FROM rducks_table_dynamic_args('labels') ORDER BY label")
  expect_equal(names(dyn_labels), "label")
  expect_equal(dyn_labels$label, c("a", "b"))

  invisible(rducks_register_table(
    con,
    "rducks_table_null_arg",
    function(x) data.frame(is_null = is.null(x)),
    chunk_size = 2L
  ))
  null_arg <- DBI::dbGetQuery(con, "SELECT * FROM rducks_table_null_arg(NULL)")
  expect_true(isTRUE(null_arg$is_null[[1L]]))

  invisible(rducks_register_table(
    con,
    "rducks_table_complex_args",
    function(items, rec) data.frame(n = length(items), total = sum(unlist(items)), a = rec$a, b_len = length(rec$b)),
    chunk_size = 2L
  ))
  complex_args <- DBI::dbGetQuery(con, "SELECT * FROM rducks_table_complex_args([1,2,3], struct_pack(a := 5, b := ['x','y']))")
  expect_equal(complex_args$n[[1L]], 3L)
  expect_equal(complex_args$total[[1L]], 6L)
  expect_equal(complex_args$a[[1L]], 5L)
  expect_equal(complex_args$b_len[[1L]], 2L)

  invisible(rducks_register_table(
    con,
    "rducks_table_bad_lengths",
    function() list(i = 1:2, label = c("a", "b", "c")),
    chunk_size = 2L
  ))
  expect_error(
    DBI::dbGetQuery(con, "SELECT * FROM rducks_table_bad_lengths()"),
    "equal lengths"
  )

  invisible(rducks_register_table(
    con,
    "rducks_table_error",
    function() stop("table boom", call. = FALSE),
    chunk_size = 2L
  ))
  expect_error(
    DBI::dbGetQuery(con, "SELECT * FROM rducks_table_error()"),
    "table boom"
  )

  invisible(rducks_register_table(
    con,
    "rducks_table_unnamed",
    function() list(1:2),
    chunk_size = 2L
  ))
  expect_error(
    DBI::dbGetQuery(con, "SELECT * FROM rducks_table_unnamed()"),
    "columns must be named|result columns must be named"
  )

  invisible(rducks_register_table(
    con,
    "rducks_table_duplicate",
    function() structure(list(1:2, 3:4), names = c("x", "x")),
    chunk_size = 2L
  ))
  expect_error(
    DBI::dbGetQuery(con, "SELECT * FROM rducks_table_duplicate()"),
    "column names must be unique|result column names must be unique"
  )

  invisible(rducks_register_table(
    con,
    "rducks_table_unsupported",
    function() list(x = list(1L, 2L)),
    chunk_size = 2L
  ))
  expect_error(
    DBI::dbGetQuery(con, "SELECT * FROM rducks_table_unsupported()"),
    "unsupported Rducks table column type"
  )

  expect_error(
    rducks_register_table(con, "rducks_table_variadic", function(...) data.frame(i = 1L)),
    "variadic"
  )
  expect_error(
    rducks_register_table(con, "rducks_table_bad_chunk", function() data.frame(i = 1L), chunk_size = 0L),
    "chunk_size"
  )
})
