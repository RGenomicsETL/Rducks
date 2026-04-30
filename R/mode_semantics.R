rducks_mode_semantics_rows <- list(
  row = list(
    mode = "row",
    status = "implemented",
    call_granularity = "one R call per row",
    input_shape = "one scalar/composite R value per declared argument",
    return_shape = "one scalar/composite R value compatible with the declared return type",
    null_semantics = "default NULL-in/NULL-out short-circuits; special mode passes row-shaped NA/NULL values",
    length_semantics = "one output value per callback invocation",
    error_semantics = "callback or marshalling errors abort the query unless exception_handling = 'return_null'",
    threading = "requires single-thread DuckDB execution for direct R callbacks",
    copy_semantics = "row values are boxed/copied into R objects; exact/exotic types use Rducks value classes",
    notes = "current production path"
  ),
  nanoarrow_lapply = list(
    mode = "nanoarrow_lapply",
    status = "reserved",
    call_granularity = "planned one R call per DuckDB vector chunk",
    input_shape = "planned nanoarrow-backed chunk arrays converted to R vectors/lists before calling the R function",
    return_shape = "planned R vector/list result with exactly the chunk length and declared return type",
    null_semantics = "planned per-element validity bitmap mapped to R NA/NULL using row-mode child semantics",
    length_semantics = "planned no recycling: result length must match the input chunk length",
    error_semantics = "planned callback or marshalling errors abort the chunk/query unless exception handling maps the whole failing chunk to NULL",
    threading = "requires the future main-R-thread pump before multi-threaded DuckDB execution is enabled",
    copy_semantics = "planned convenience path; may materialize R vectors/lists from nanoarrow arrays",
    notes = "not implemented; intended high-level batch lapply path"
  ),
  arrow_nanoarrow = list(
    mode = "arrow_nanoarrow",
    status = "reserved",
    call_granularity = "planned one R call per DuckDB vector chunk or ArrowArrayStream batch",
    input_shape = "planned nanoarrow ArrowArray/ArrowSchema objects or stream wrappers",
    return_shape = "planned nanoarrow-compatible Arrow array with declared return schema and chunk length",
    null_semantics = "planned Arrow validity bitmap semantics; R NULL represents a top-level failure/null result only where explicitly allowed",
    length_semantics = "planned output array length must match the input chunk length",
    error_semantics = "planned callback, schema, length, or release-callback errors abort unless exception handling maps the chunk to NULL",
    threading = "requires the future main-R-thread pump and explicit Arrow C Data Interface ownership rules",
    copy_semantics = "planned lower-level path preserving Arrow C Data Interface buffers where safe",
    notes = "not implemented; intended low-level nanoarrow/Arrow C Data Interface path"
  )
)

#' Describe Rducks execution mode semantics
#'
#' `rducks_mode_semantics()` is the package-level schema for row and future
#' batch execution modes. It intentionally documents reserved modes as reserved,
#' so README/pkgdown text can describe the intended contract without pretending
#' that native batch registration is implemented.
#'
#' `mode = "row"` is currently implemented. `mode = "nanoarrow_lapply"` is the
#' planned high-level batch convenience path: Rducks will use nanoarrow-backed
#' chunk arrays internally, materialize R vectors/lists for the callback, and
#' require a return value with exactly the input chunk length. `mode =
#' "arrow_nanoarrow"` is the planned lower-level Arrow C Data Interface path
#' where callbacks work with nanoarrow/Arrow array objects directly.
#'
#' @param mode Optional character vector of mode names. When `NULL`, all known
#'   modes are returned.
#' @return A data frame describing status, call granularity, input and return
#'   shape, NULL handling, length checks, error behavior, threading, and copy
#'   semantics for each mode.
#' @export
rducks_mode_semantics <- function(mode = NULL) {
  modes <- names(rducks_mode_semantics_rows)
  if (is.null(mode)) {
    selected <- modes
  } else {
    if (!is.character(mode)) {
      stop("mode must be a character vector", call. = FALSE)
    }
    bad <- setdiff(mode, modes)
    if (length(bad)) {
      stop("unknown Rducks mode: ", paste(bad, collapse = ", "), call. = FALSE)
    }
    selected <- mode
  }
  rows <- lapply(selected, function(name) {
    as.data.frame(rducks_mode_semantics_rows[[name]], stringsAsFactors = FALSE, check.names = FALSE)
  })
  out <- if (length(rows)) do.call(rbind, rows) else {
    data.frame(
      mode = character(), status = character(), call_granularity = character(),
      input_shape = character(), return_shape = character(), null_semantics = character(),
      length_semantics = character(), error_semantics = character(), threading = character(),
      copy_semantics = character(), notes = character(),
      stringsAsFactors = FALSE, check.names = FALSE
    )
  }
  row.names(out) <- NULL
  out
}
