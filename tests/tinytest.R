Sys.setenv(RDUCKS_DEV_SURFACES = "true")
`%||%` <- if (exists("%||%", envir = baseenv(), mode = "function", inherits = FALSE)) {
  get("%||%", envir = baseenv(), mode = "function", inherits = FALSE)
} else {
  function(x, y) if (is.null(x)) y else x
}
library(Rducks)
if (requireNamespace("tinytest", quietly = TRUE)) {
  tinytest::test_package("Rducks")
}
