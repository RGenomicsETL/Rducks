#' Rducks: R user-defined functions for DuckDB
#'
#' Rducks is an experimental R package and DuckDB extension bridge for
#' registering R functions as DuckDB user-defined functions.
#'
#' The design keeps the DuckDB extension as the canonical execution surface and
#' uses R for ergonomic registration, callback lifetime management, and optional
#' code generation through Rtinycc.
#'
#' @keywords internal
"_PACKAGE"

#' @import duckdb
#' @import methods
#' @importFrom DBI dbExecute
#' @importFrom Rtinycc tcc_add_include_path tcc_add_library tcc_add_library_path tcc_compile_string tcc_get_symbol tcc_relocate tcc_state tcc_symbol_is_valid
#' @useDynLib Rducks, .registration = TRUE
NULL
