#' Register an R callback token
#'
#' Registers an R function with the native Rducks callback registry. The returned
#' external pointer preserves the function until it is closed or garbage
#' collected.
#'
#' @param fun R function.
#' @return External pointer with class `rducks_callback`.
#' @export
rducks_callback <- function(fun) {
  if (!is.function(fun)) {
    stop("fun must be a function", call. = FALSE)
  }
  out <- .Call(RDUCKS_callback_register, fun)
  class(out) <- c("rducks_callback", "externalptr")
  out
}

#' Close an Rducks callback token
#'
#' @param callback A callback returned by [rducks_callback()].
#' @return `NULL`, invisibly.
#' @export
rducks_callback_close <- function(callback) {
  if (!inherits(callback, "rducks_callback")) {
    stop("callback must be a rducks_callback", call. = FALSE)
  }
  .Call(RDUCKS_callback_close, callback)
  invisible(NULL)
}

#' Invoke an Rducks callback token
#'
#' This helper is intended for tests and for validating marshalling behavior. In
#' the DuckDB extension, callbacks are normally invoked from native trampoline
#' code or through the main-thread pump.
#'
#' @param callback A callback returned by [rducks_callback()].
#' @param args List of R arguments.
#' @return Callback result.
#' @export
rducks_callback_invoke <- function(callback, args = list()) {
  if (!inherits(callback, "rducks_callback")) {
    stop("callback must be a rducks_callback", call. = FALSE)
  }
  if (!is.list(args)) {
    stop("args must be a list", call. = FALSE)
  }
  .Call(RDUCKS_callback_invoke, callback, args)
}

#' Pump pending Rducks callback requests
#'
#' Worker-thread DuckDB UDF requests are drained internally by the loaded Rducks
#' extension whenever execution reaches the calling R thread. This helper is kept
#' as a public pump hook and currently returns the number of package-local
#' requests processed by the R package runtime.
#'
#' @return Integer count of package-local requests processed.
#' @export
rducks_pump <- function() {
  .Call(RDUCKS_pump)
}
