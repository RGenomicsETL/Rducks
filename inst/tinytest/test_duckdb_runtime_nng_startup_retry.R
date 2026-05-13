library(Rducks)

rducks_test_replace_namespace_value <- function(name, value) {
  ns <- asNamespace("Rducks")
  old <- get(name, envir = ns, inherits = FALSE)
  locked <- bindingIsLocked(name, ns)
  if (locked) unlockBinding(name, ns)
  assign(name, value, envir = ns)
  if (locked) lockBinding(name, ns)
  old
}

local({
  if (!"tcp" %in% Rducks:::rducks_nng_runtime_transports()) {
    expect_true(TRUE)
    return(invisible(NULL))
  }

  old_attempts <- getOption("rducks.nng.startup_attempts")
  options(rducks.nng.startup_attempts = 2L)
  on.exit(options(rducks.nng.startup_attempts = old_attempts), add = TRUE)

  old_defaults <- Rducks:::rducks_nng_defaults
  test_defaults <- old_defaults
  test_defaults$startup_timeout <- if (identical(Sys.info()[["sysname"]], "Windows")) {
    max(10, old_defaults$startup_timeout)
  } else {
    1
  }
  test_defaults$startup_retry_sleep <- 0
  invisible(rducks_test_replace_namespace_value("rducks_nng_defaults", test_defaults))
  on.exit(invisible(rducks_test_replace_namespace_value("rducks_nng_defaults", old_defaults)), add = TRUE)

  old_bundle <- get("rducks_nng_endpoint_bundle", envir = asNamespace("Rducks"), inherits = FALSE)
  calls <- 0L
  patched_bundle <- function(workers, transport = NULL) {
    calls <<- calls + 1L
    if (identical(transport, "tcp") && calls == 1L) {
      return(list(
        endpoints = rep("bad://rducks-startup-retry", workers),
        cleanup_paths = character(),
        transport = "tcp"
      ))
    }
    old_bundle(workers, transport)
  }
  invisible(rducks_test_replace_namespace_value("rducks_nng_endpoint_bundle", patched_bundle))
  on.exit(invisible(rducks_test_replace_namespace_value("rducks_nng_endpoint_bundle", old_bundle)), add = TRUE)

  provider <- Rducks:::rducks_nng_provider(workers = 1L, transport = "tcp")
  on.exit(try(provider$stop(timeout = 2, quiet = TRUE), silent = TRUE), add = TRUE)
  provider$start()
  expect_true(provider$stats()$started[[1L]])
  expect_true(calls >= 2L)
  expect_equal(provider$stats()$transport[[1L]], "tcp")
  shutdown <- provider$stop(timeout = 2, quiet = TRUE)
  expect_equal(shutdown$tasks_unresolved, 0L)
})
