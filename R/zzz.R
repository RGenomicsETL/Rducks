.rducks_state <- new.env(parent = emptyenv())

`%||%` <- if (exists("%||%", envir = baseenv(), mode = "function", inherits = FALSE)) {
  get("%||%", envir = baseenv(), mode = "function", inherits = FALSE)
} else {
  function(x, y) if (is.null(x)) y else x
}

rducks_main_thread_token <- function() {
  token <- .rducks_state$main_thread_token
  if (is.null(token)) {
    token <- .Call(RDUCKS_current_thread_token)
    .rducks_state$main_thread_token <- token
  }
  token
}

.onLoad <- function(libname, pkgname) {
  .rducks_state$main_thread_token <- .Call(RDUCKS_current_thread_token)
  reg.finalizer(.rducks_state, function(env) {
    rducks_nng_stop_all_providers(quiet = TRUE)
    invisible(NULL)
  }, onexit = TRUE)
  S7::methods_register()
}
