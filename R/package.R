#' Rducks: R user-defined functions for DuckDB
#'
#' Rducks is an R package and DuckDB extension bridge for registering R
#' functions as DuckDB user-defined functions.
#'
#' The design keeps the DuckDB extension as the canonical execution surface and
#' uses R for ergonomic registration, callback lifetime management, and scalar
#' callback execution over DuckDB chunks.
#'
#' @keywords internal
"_PACKAGE"

#' @import duckdb
#' @import methods
#' @importFrom DBI dbExecute
#' @useDynLib Rducks, .registration = TRUE
NULL
