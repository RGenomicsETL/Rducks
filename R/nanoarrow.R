#' Check for nanoarrow support
#'
#' @return Logical scalar indicating whether the optional `nanoarrow` package is
#'   installed.
#' @export
rducks_has_nanoarrow <- function() {
  requireNamespace("nanoarrow", quietly = TRUE)
}

rducks_assert_nanoarrow <- function() {
  if (!rducks_has_nanoarrow()) {
    stop("nanoarrow is required for Arrow C Data Interface UDF paths", call. = FALSE)
  }
  invisible(TRUE)
}

#' Plan an Arrow-batch UDF shape
#'
#' Arrow/nanoarrow support is intentionally kept as an in-process Arrow C Data
#' Interface path, not an IPC path. This helper records the intended batch UDF
#' shape before native registration is wired in.
#'
#' @param name SQL function name.
#' @param fun R function that will receive or return Arrow-compatible objects.
#' @param schema Optional nanoarrow schema object or schema descriptor.
#' @return A list of class `rducks_arrow_udf_spec`.
#' @export
rducks_arrow_udf_spec <- function(name, fun, schema = NULL) {
  if (!is.character(name) || length(name) != 1L || !nzchar(name)) {
    stop("name must be a non-empty character scalar", call. = FALSE)
  }
  if (!is.function(fun)) {
    stop("fun must be a function", call. = FALSE)
  }
  structure(
    list(name = name, fun = fun, schema = schema),
    class = "rducks_arrow_udf_spec"
  )
}
