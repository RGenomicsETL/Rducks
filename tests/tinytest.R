Sys.setenv(RDUCKS_DEV_SURFACES = "true")
library(Rducks)
if (requireNamespace("tinytest", quietly = TRUE)) {
  tinytest::test_package("Rducks")
}
