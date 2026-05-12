library(Rducks)

local({
  helper_offset <- 2L
  globals <- Rducks:::rducks_ipc_worker_globals(function() helper_offset, "auto")
  expect_true("helper_offset" %in% names(globals$globals))
  expect_equal(globals$globals$helper_offset, 2L)

  explicit <- Rducks:::rducks_ipc_worker_globals(function() helper_offset, FALSE)
  expect_equal(explicit$globals, list())
  expect_equal(explicit$packages, character())

  by_name <- Rducks:::rducks_ipc_worker_globals(function() helper_offset, "helper_offset")
  expect_equal(by_name$globals$helper_offset, 2L)

  null_global <- NULL
  by_null_name <- Rducks:::rducks_ipc_worker_globals(function() null_global, "null_global")
  expect_true("null_global" %in% names(by_null_name$globals))
  expect_true(is.null(by_null_name$globals$null_global))

  merged <- Rducks:::rducks_ipc_worker_globals(function() helper_offset, list(extra = 1L))
  expect_equal(merged$globals$extra, 1L)
  expect_error(
    Rducks:::rducks_ipc_worker_globals(function() helper_offset, list(1L)),
    "must have unique non-empty names"
  )

  if (requireNamespace("globals", quietly = TRUE)) {
    masked_global <- 42L
    dfs_globals <- Rducks:::rducks_ipc_worker_globals(function() {
      local_value <- masked_global
      masked_global <- 1L
      local_value
    }, "auto")
    expect_equal(dfs_globals$globals$masked_global, 42L)

    outer_x <- 2L
    nested_globals <- Rducks:::rducks_ipc_worker_globals(function() {
      local({
        h <- function(outer_x) -outer_x
        h(outer_x)
      })
    }, "auto")
    expect_equal(nested_globals$globals$outer_x, 2L)
  }
})

local({
  old_warn <- getOption("rducks.ipc_globals.warn_bytes")
  old_max <- getOption("rducks.ipc_globals.max_bytes")
  on.exit({
    options(rducks.ipc_globals.warn_bytes = old_warn)
    options(rducks.ipc_globals.max_bytes = old_max)
  }, add = TRUE)

  small_global <- 1L
  options(rducks.ipc_globals.warn_bytes = Inf, rducks.ipc_globals.max_bytes = Inf)
  expect_silent(Rducks:::rducks_ipc_worker_globals(function() small_global, "auto"))

  large_global <- raw(256)
  options(rducks.ipc_globals.warn_bytes = 1, rducks.ipc_globals.max_bytes = Inf)
  expect_warning(
    Rducks:::rducks_ipc_worker_globals(function() length(large_global), "auto"),
    "ipc_globals = 'auto' captured"
  )

  options(rducks.ipc_globals.warn_bytes = 1, rducks.ipc_globals.max_bytes = Inf)
  expect_silent(Rducks:::rducks_ipc_worker_globals(function() length(large_global), "large_global"))

  options(rducks.ipc_globals.warn_bytes = Inf, rducks.ipc_globals.max_bytes = 1)
  expect_error(
    Rducks:::rducks_ipc_worker_globals(function() length(large_global), "auto"),
    "rducks.ipc_globals.max_bytes"
  )
})

local({
  if (requireNamespace("mori", quietly = TRUE)) {
    large_global <- rnorm(10000)
    plain <- Rducks:::rducks_ipc_worker_globals(function() large_global[[1L]], "auto")
    shared <- Rducks:::rducks_ipc_worker_globals(function() large_global[[1L]], "auto", share = "mori")
    plain_size <- length(serialize(plain$globals, NULL, xdr = FALSE))
    shared_size <- length(serialize(shared$globals, NULL, xdr = FALSE))
    expect_true(shared_size < plain_size / 10)
    expect_true("mori" %in% shared$packages)
  } else {
    expect_error(
      Rducks:::rducks_ipc_worker_globals(function() 1L, list(x = 1L), share = "mori"),
      "mori package"
    )
  }
})

local({
  input_array <- nanoarrow::as_nanoarrow_array(data.frame(arg1 = 1:3))
  input_payload <- Rducks:::rducks_arrow_ipc_encode(input_array)
  output_schema_spec <- Rducks:::rducks_arrow_schema_to_spec(
    nanoarrow::infer_nanoarrow_schema(data.frame(result = integer()))
  )
  output_payload <- Rducks:::rducks_ipc_worker_eval_arrow_ipc_chunk(
    input_payload = input_payload,
    output_schema_spec = output_schema_spec,
    n = 3L,
    fun = function(x) x + 1L,
    arg_types = list(INTEGER),
    return_type = INTEGER,
    null_handling = "default",
    exception_handling = "rethrow",
    mode = "vectorized"
  )
  expect_true(is.raw(input_payload))
  expect_true(is.raw(output_payload))
  decoded_output <- Rducks:::rducks_arrow_ipc_decode_array(output_payload)
  expect_equal(as.data.frame(decoded_output$array)$result, 2:4)
})
