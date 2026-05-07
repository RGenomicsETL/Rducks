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
    threading = "R API work for arrow_r/arrow_c runs on the recorded main R thread; arrow_ipc + multiprocess_parallel evaluates scalar rows inside provider workers after Arrow IPC encoding",
    copy_semantics = "DuckDB chunks are exported/imported through Arrow C Data for in-process plans; arrow_ipc plans copy chunk/task payloads into Arrow IPC raw bytes before process transport",
    notes = "scalar arrow_ipc loops over rows inside the worker; in-process queuing is available for deadlock-safe same-process scheduling, not for parallel R evaluation"
  ),
  vectorized = list(
    mode = "vectorized",
    status = "implemented",
    call_granularity = "one R call per DuckDB chunk",
    input_shape = "one R vector/list-column per declared argument",
    return_shape = "one R vector/list of values compatible with the declared return type",
    null_semantics = "default mode evaluates only rows with no top-level SQL NULL inputs and scatters SQL NULLs back; special mode passes all rows with scalar-shaped NA/NULL values",
    length_semantics = "return length must equal the number of evaluated rows in the chunk",
    error_semantics = "R function errors make all evaluated rows SQL NULL with exception_handling = 'return_null'; type-checking and marshalling errors abort the query",
    threading = "arrow_r and arrow_c vectorized work runs on the recorded main R thread; arrow_ipc + multiprocess_parallel offloads vectorized chunk work through the selected worker provider",
    copy_semantics = "arrow_r vectorized chunks are exported/imported through Arrow C Data; arrow_c vectorized materializes supported DuckDB vectors directly in native C; arrow_ipc plans copy chunk/task payloads into Arrow IPC raw bytes before process transport",
    notes = "batch/chunk call-shape used by arrow_r, direct arrow_c, and Arrow IPC worker-provider backends; zero-argument vectorized UDFs are not exposed yet"
  )
)

rducks_match_mode <- function(mode) {
  mode <- match.arg(mode, names(rducks_mode_semantics_rows))
  mode
}

#' Describe Rducks execution mode semantics
#'
#' `rducks_mode_semantics()` is the package-level schema for execution-mode
#' semantics. `mode = "scalar"` calls the R function once for each DuckDB row.
#' `mode = "vectorized"` calls the R function once per DuckDB chunk with one R
#' vector/list-column per declared argument. Vectorized mode is exposed for
#' `arrow_r`, direct `arrow_c`, and worker-provider `arrow_ipc` plans.
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
