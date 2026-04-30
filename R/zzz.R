.rducks_state <- new.env(parent = emptyenv())

rducks_main_thread_token <- function() {
  token <- .rducks_state$main_thread_token
  if (is.null(token)) {
    token <- if (identical(.Platform$OS.type, "windows")) .Call(RDUCKS_current_thread_token) else ""
    .rducks_state$main_thread_token <- token
  }
  token
}

.onLoad <- function(libname, pkgname) {
  .rducks_state$main_thread_token <- if (identical(.Platform$OS.type, "windows")) {
    .Call(RDUCKS_current_thread_token)
  } else {
    ""
  }
  S7::methods_register()
}
