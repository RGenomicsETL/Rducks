.rducks_state <- new.env(parent = emptyenv())

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
  S7::methods_register()
}
