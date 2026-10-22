rducks_mode_semantics_rows <- list(
  scalar = list(
    mode = "scalar",
    status = "implemented",
    call_granularity = "one R call per row",
    input_shape = "one scalar/composite R value per declared or dynamically bound argument",
    return_shape = "one scalar/composite R value compatible with the declared return type",
    null_semantics = "default NULL-in/NULL-out short-circuits; special mode passes scalar-shaped NA/NULL values",
    length_semantics = "one output value per R function call",
    error_semantics = "R function errors become SQL NULL with exception_handling = 'return_null'; type-checking and marshalling errors abort the query",
    threading = "direct in-process R API work runs on the recorded main R thread; queued in-process calls are drained by that thread",
    copy_semantics = "DuckDB vectors are materialized directly to R values",
    notes = "the ipc (wire) transport covers fixed-width scalars, VARCHAR/BLOB, DECIMAL, INTERVAL, ENUM, BIT, GEOMETRY, MAP, UNION, VARIANT, and LIST/ARRAY/STRUCT of supported types; VARIANT is runtime-probed and fail-closed"
  ),
  vectorized = list(
    mode = "vectorized",
    status = "implemented",
    call_granularity = "one R call per DuckDB chunk by default; coalesce = TRUE permits merging queued chunks",
    input_shape = "one R vector/list-column per declared or dynamically bound argument",
    return_shape = "one R vector/list of values compatible with the declared return type",
    null_semantics = "default mode evaluates only rows with no top-level SQL NULL inputs and scatters SQL NULLs back; special mode passes all rows with scalar-shaped NA/NULL values",
    length_semantics = "return length must equal the number of evaluated rows in the R call; NULL returns SQL NULL for all rows",
    error_semantics = "R function errors make all evaluated rows in the original chunk SQL NULL with exception_handling = 'return_null'; coalescing requires 'rethrow'; type-checking and marshalling errors abort the query",
    threading = "direct vectorized work runs on the recorded main R thread; queued in-process calls are drained by that thread",
    copy_semantics = "DuckDB vectors are materialized directly to R vectors/list-columns",
    notes = "coalesce = TRUE requires a static direct signature with plain scalar inputs, no side effects, and results invariant to combining chunks; zero-argument vectorized UDFs are not exposed yet"
  )
)

rducks_match_mode <- function(mode) {
  mode <- match.arg(mode, names(rducks_mode_semantics_rows))
  mode
}

#' Describe Rducks scalar-UDF evaluation mode semantics
#'
#' `rducks_mode_semantics()` is the package-level schema for Rducks evaluation
#' modes used by DuckDB scalar UDFs registered with
#' \code{\link[=rducks_register_scalar_udf]{rducks_register_scalar_udf()}}. This
#' is distinct from DuckDB function kind (scalar, aggregate, or table) and from
#' Rducks execution plans. `mode = "scalar"` calls the R function once for each
#' DuckDB row. `mode = "vectorized"` calls the R function once per DuckDB chunk
#' by default, with one R vector/list-column per declared or dynamically bound
#' argument. An in-process registration can explicitly permit merging queued
#' chunks with `coalesce = TRUE` when its results are invariant to that change
#' in call boundaries. See the registration function for the supported
#' signatures and error policy. Vectorized mode is available with both the
#' direct and IPC backends for their supported signatures.
#'
#' @param mode Optional character vector of scalar-UDF evaluation mode names.
#'   When `NULL`, all known modes are returned.
#' @return A data frame describing status, call granularity, input and return
#'   shape, NULL handling, length checks, error behavior, threading, and copy
#'   semantics for each scalar-UDF evaluation mode.
#' @examples
#' rducks_mode_semantics()
#' rducks_mode_semantics("scalar")
#' rducks_mode_semantics("vectorized")
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
