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
    threading = "requires callbacks to execute on the calling R thread; rducks_enable(..., threads = 'single') sets external_threads=1 and threads=1, and native guards refuse worker-thread R calls",
    copy_semantics = "row values are boxed/copied into R objects; exact/exotic types use Rducks value classes",
    notes = "current production path"
  )
)

#' Describe Rducks execution mode semantics
#'
#' `rducks_mode_semantics()` is the package-level schema for execution-mode
#' semantics. `mode = "row"` is currently the only public mode: Rducks calls the
#' R callback once for each DuckDB row. Future chunk or Arrow-backed execution
#' modes will be added only when they execute real UDFs.
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
