library(Rducks)

local({
  `%||%` <- function(x, y) if (is.null(x)) y else x
  desc <- packageDescription("Rducks")
  deps <- paste(desc$Imports %||% "", desc$LinkingTo %||% "")
  expect_false(grepl("nanoarrow", deps, ignore.case = TRUE))
  expect_false(dir.exists(system.file("rducks_extension", "third_party", "na", package = "Rducks")))
  expect_true(file.exists(rducks_extension_path()))
})
