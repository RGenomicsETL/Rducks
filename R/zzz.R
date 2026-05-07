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

rducks_cache_nanoarrow_dll_path <- function() {
  path <- .rducks_state$nanoarrow_dll_path
  if (is.character(path) && length(path) == 1L && !is.na(path) && nzchar(path)) {
    return(path)
  }
  getNamespace("nanoarrow")
  dll <- getLoadedDLLs()[["nanoarrow"]]
  if (is.null(dll) || is.null(dll[["path"]])) {
    stop("nanoarrow shared library is not loaded", call. = FALSE)
  }
  path <- dll[["path"]]
  .rducks_state$nanoarrow_dll_path <- path
  path
}

.onLoad <- function(libname, pkgname) {
  .rducks_state$main_thread_token <- .Call(RDUCKS_current_thread_token)
  .rducks_state$nanoarrow_dll_path <- tryCatch(
    rducks_cache_nanoarrow_dll_path(),
    error = function(e) NULL
  )
  reg.finalizer(.rducks_state, function(env) {
    rducks_mirai_stop_all_providers()
    invisible(NULL)
  }, onexit = TRUE)
  S7::methods_register()
}
