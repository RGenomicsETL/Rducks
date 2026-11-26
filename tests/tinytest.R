Sys.setenv(RDUCKS_DEV_SURFACES = "true")
`%||%` <- if (exists("%||%", envir = baseenv(), mode = "function", inherits = FALSE)) {
  get("%||%", envir = baseenv(), mode = "function", inherits = FALSE)
} else {
  function(x, y) if (is.null(x)) y else x
}
library(Rducks)
if (requireNamespace("tinytest", quietly = TRUE)) {
  # A development version (four components) also runs the tests that need
  # more than two threads; a release version, as on CRAN, does not.
  at_home <- length(unclass(utils::packageVersion("Rducks"))[[1L]]) == 4L
  tinytest::test_package("Rducks", at_home = at_home)
}
