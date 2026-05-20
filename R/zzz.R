.rducks_state <- new.env(parent = emptyenv())

`%||%` <- if (exists("%||%", envir = baseenv(), mode = "function", inherits = FALSE)) {
  get("%||%", envir = baseenv(), mode = "function", inherits = FALSE)
} else {
  function(x, y) if (is.null(x)) y else x
}

rducks_get_or_init_store <- function(key, hash = FALSE) {
  store <- .rducks_state[[key]]
  if (is.null(store)) {
    store <- new.env(parent = emptyenv(), hash = hash)
    .rducks_state[[key]] <- store
  }
  store
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
    # This finalizer runs at R session exit.  Mirai daemon processes are
    # children of R and are killed by the OS on exit, so we do not need to
    # send NNG stop requests.  Calling nanonext at this point is unsafe:
    # its C-level AIO objects may already be garbage-collected, causing
    # crashes.  Skip the NNG cleanup here; only call it during a mid-session
    # forced teardown (e.g. rducks_nng_stop_all_providers() from user code).
    invisible(NULL)
  }, onexit = TRUE)
  S7::methods_register()
}
