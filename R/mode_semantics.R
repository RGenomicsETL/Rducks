rducks_mode_semantics_rows <- list(
  scalar = list(
    mode = "scalar",
    status = "implemented",
    call_granularity = "one R call per row",
    input_shape = "one scalar/composite R value per declared argument",
    return_shape = "one scalar/composite R value compatible with the declared return type",
    null_semantics = "default NULL-in/NULL-out short-circuits; special mode passes scalar-shaped NA/NULL values",
    length_semantics = "one output value per R function call",
    error_semantics = "R function errors become SQL NULL with exception_handling = 'return_null'; type-checking and marshalling errors abort the query",
    threading = "R API work runs on the calling R thread; rducks_enable(..., threads = 'single') sets external_threads=1 and threads=1, and registration enforces this supported configuration",
    copy_semantics = "DuckDB chunks are exported/imported through Arrow C Data; the nanoarrow scalar adapter materializes one R function value per DuckDB row",
    notes = "current production path; a vectorized mode should call R once per DuckDB chunk and is not exposed until implemented"
  )
)

#' Describe Rducks execution mode semantics
#'
#' `rducks_mode_semantics()` is the package-level schema for execution-mode
#' semantics. `mode = "scalar"` is currently the only public mode: Rducks calls
#' the R function once for each DuckDB row. Scalar mode is implemented on top of
#' DuckDB Arrow C Data export/import plus nanoarrow. A future vectorized mode
#' should call R once per DuckDB chunk and will be added only when implemented.
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
