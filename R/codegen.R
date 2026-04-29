#' Create an Rducks UDF specification
#'
#' @param name SQL function name.
#' @param fun R function.
#' @param args Character vector of Rducks type tokens.
#' @param returns Return type token.
#' @param mode Registration mode. The implemented scalar path uses
#'   `"compiled"` Rtinycc-generated wrappers.
#' @return Object of class `rducks_udf_spec`.
#' @export
rducks_udf_spec <- function(name, fun, args, returns, mode = c("compiled")) {
  mode <- match.arg(mode)
  if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)) {
    stop("name must be a non-empty character scalar", call. = FALSE)
  }
  if (!is.function(fun)) {
    stop("fun must be a function", call. = FALSE)
  }
  args <- rducks_types_normalize(args)
  returns <- rducks_type_normalize(returns)
  structure(
    list(
      name = name,
      fun = fun,
      args = args,
      returns = returns,
      mode = mode,
      signature = rducks_duckdb_signature(name, args, returns)
    ),
    class = "rducks_udf_spec"
  )
}

#' @export
print.rducks_udf_spec <- function(x, ...) {
  cat("<rducks_udf_spec>\n")
  cat("  name:      ", x$name, "\n", sep = "")
  cat("  mode:      ", x$mode, "\n", sep = "")
  cat("  signature: ", x$signature, "\n", sep = "")
  invisible(x)
}

rducks_c_identifier <- function(x) {
  x <- gsub("[^A-Za-z0-9_]", "_", x)
  if (!grepl("^[A-Za-z_]", x)) {
    x <- paste0("_", x)
  }
  x
}

rducks_codegen_hash <- function(x) {
  ints <- utf8ToInt(paste(x, collapse = "\n"))
  h <- 0
  for (i in ints) {
    h <- (h * 131 + i) %% 2147483647
  }
  sprintf("%08x", as.integer(h))
}

rducks_c_arg_expr <- function(token, index) {
  switch(token,
    bool = sprintf(
      "arg_values[%d] = PROTECT(arg_is_null[%d] ? Rf_ScalarLogical(NA_LOGICAL) : Rf_ScalarLogical((*(bool *)args[%d]) ? TRUE : FALSE));",
      index, index, index
    ),
    i32 = sprintf(
      "arg_values[%d] = PROTECT(arg_is_null[%d] ? Rf_ScalarInteger(NA_INTEGER) : Rf_ScalarInteger((int)*(int32_t *)args[%d]));",
      index, index, index
    ),
    i64 = sprintf(
      "arg_values[%d] = PROTECT(arg_is_null[%d] ? Rf_ScalarReal(NA_REAL) : Rf_ScalarReal((double)*(int64_t *)args[%d]));",
      index, index, index
    ),
    f32 = sprintf(
      "arg_values[%d] = PROTECT(arg_is_null[%d] ? Rf_ScalarReal(NA_REAL) : Rf_ScalarReal((double)*(float *)args[%d]));",
      index, index, index
    ),
    f64 = sprintf(
      "arg_values[%d] = PROTECT(arg_is_null[%d] ? Rf_ScalarReal(NA_REAL) : Rf_ScalarReal(*(double *)args[%d]));",
      index, index, index
    ),
    varchar = sprintf(
      "arg_values[%d] = PROTECT(arg_is_null[%d] ? Rf_ScalarString(NA_STRING) : Rf_mkString(*(const char **)args[%d]));",
      index, index, index
    ),
    stop("unsupported generated argument type: ", token, call. = FALSE)
  )
}

rducks_c_return_lines <- function(token) {
  switch(token,
    bool = c(
      "  int value = Rf_asLogical(result);",
      "  if (value == NA_LOGICAL) {",
      "    if (out_is_null) *out_is_null = true;",
      "  } else {",
      "    *(bool *)out_value = value == TRUE;",
      "    if (out_is_null) *out_is_null = false;",
      "  }"
    ),
    i32 = c(
      "  int value = Rf_asInteger(result);",
      "  if (value == NA_INTEGER) {",
      "    if (out_is_null) *out_is_null = true;",
      "  } else {",
      "    *(int32_t *)out_value = (int32_t)value;",
      "    if (out_is_null) *out_is_null = false;",
      "  }"
    ),
    i64 = c(
      "  double value = Rf_asReal(result);",
      "  if (ISNA(value)) {",
      "    if (out_is_null) *out_is_null = true;",
      "  } else {",
      "    *(int64_t *)out_value = (int64_t)value;",
      "    if (out_is_null) *out_is_null = false;",
      "  }"
    ),
    f32 = c(
      "  double value = Rf_asReal(result);",
      "  if (ISNA(value)) {",
      "    if (out_is_null) *out_is_null = true;",
      "  } else {",
      "    *(float *)out_value = (float)value;",
      "    if (out_is_null) *out_is_null = false;",
      "  }"
    ),
    f64 = c(
      "  double value = Rf_asReal(result);",
      "  if (ISNA(value)) {",
      "    if (out_is_null) *out_is_null = true;",
      "  } else {",
      "    *(double *)out_value = value;",
      "    if (out_is_null) *out_is_null = false;",
      "  }"
    ),
    varchar = c(
      "  SEXP str_vec;",
      "  int str_protected = 0;",
      "  if (result == R_NilValue || XLENGTH(result) == 0) {",
      "    if (out_is_null) *out_is_null = true;",
      "  } else {",
      "    if (TYPEOF(result) == STRSXP) {",
      "      str_vec = result;",
      "    } else {",
      "      str_vec = PROTECT(Rf_coerceVector(result, STRSXP));",
      "      str_protected = 1;",
      "    }",
      "    if (XLENGTH(str_vec) == 0 || STRING_ELT(str_vec, 0) == NA_STRING) {",
      "      if (out_is_null) *out_is_null = true;",
      "    } else {",
      "      *(const char **)out_value = Rf_translateCharUTF8(STRING_ELT(str_vec, 0));",
      "      if (out_is_null) *out_is_null = false;",
      "    }",
      "    if (str_protected) UNPROTECT(1);",
      "  }"
    ),
    stop("unsupported generated return type: ", token, call. = FALSE)
  )
}

#' Generate C source for a scalar R UDF wrapper
#'
#' The generated function has the fixed native ABI used by the Rducks DuckDB
#' extension: `bool fn(SEXP fun, void **args, const bool *arg_is_null,
#' void *out_value, bool *out_is_null)`. The extension handles DuckDB vector
#' access and the generated wrapper handles only shape-specific R marshalling.
#'
#' @param spec A [rducks_udf_spec()] object.
#' @param symbol Optional C symbol name.
#' @return Character scalar C source with attributes `symbol` and `hash`.
#' @export
rducks_generate_scalar_wrapper <- function(spec, symbol = NULL) {
  if (!inherits(spec, "rducks_udf_spec")) {
    stop("spec must be a rducks_udf_spec", call. = FALSE)
  }
  key <- c(spec$name, spec$args, spec$returns)
  hash <- rducks_codegen_hash(key)
  symbol <- symbol %||% paste0("rducks_wrap_", rducks_c_identifier(spec$name), "_", hash)
  n_args <- length(spec$args)

  arg_lines <- if (n_args) {
    unlist(Map(rducks_c_arg_expr, spec$args, seq_len(n_args) - 1L), use.names = FALSE)
  } else {
    character()
  }
  return_lines <- rducks_c_return_lines(spec$returns)

  src <- paste(
    "#define _Complex",
    "#include <R.h>",
    "#include <Rinternals.h>",
    "#include <stdbool.h>",
    "#include <stdint.h>",
    "#include <stddef.h>",
    "",
    sprintf("bool %s(SEXP fun, void **args, const bool *arg_is_null, void *out_value, bool *out_is_null) {", symbol),
    sprintf("  SEXP arg_values[%d];", max(n_args, 1L)),
    "  SEXP pair = R_NilValue;",
    "  SEXP call;",
    "  SEXP result;",
    "  int protect_count = 0;",
    "  int err = 0;",
    if (n_args) paste0("  ", arg_lines, collapse = "\n") else "  (void)args;\n  (void)arg_is_null;\n  (void)arg_values;",
    if (n_args) sprintf("  protect_count += %d;", n_args) else "",
    if (n_args) sprintf("  for (size_t i = %d; i > 0; --i) {", n_args) else "  for (size_t i = 0; i > 0; --i) {",
    "    pair = PROTECT(Rf_cons(arg_values[i - 1], pair));",
    "    protect_count++;",
    "  }",
    "  call = PROTECT(Rf_lcons(fun, pair));",
    "  protect_count++;",
    "  result = PROTECT(R_tryEvalSilent(call, R_GlobalEnv, &err));",
    "  protect_count++;",
    "  if (err) {",
    "    if (out_is_null) *out_is_null = true;",
    "    UNPROTECT(protect_count);",
    "    return false;",
    "  }",
    "  if (result == R_NilValue || XLENGTH(result) == 0) {",
    "    if (out_is_null) *out_is_null = true;",
    "    UNPROTECT(protect_count);",
    "    return true;",
    "  }",
    paste(return_lines, collapse = "\n"),
    "  UNPROTECT(protect_count);",
    "  return true;",
    "}",
    sep = "\n"
  )
  attr(src, "symbol") <- symbol
  attr(src, "hash") <- hash
  src
}

#' Compile a scalar wrapper with Rtinycc
#'
#' @param spec A [rducks_udf_spec()] object.
#' @return Object containing the Rtinycc state, symbol pointer, symbol name, and
#'   generated source. Keep this object alive for as long as DuckDB may call the
#'   registered UDF.
#' @export
rducks_compile_scalar_wrapper <- function(spec) {
  source <- rducks_generate_scalar_wrapper(spec)
  symbol <- attr(source, "symbol", exact = TRUE)

  state <- tcc_state(output = "memory")
  status <- tcc_add_include_path(state, R.home("include"))
  if (!identical(as.integer(status), 0L)) {
    stop("failed to add R include path to Rtinycc state", call. = FALSE)
  }
  if (dir.exists(R.home("lib"))) {
    tcc_add_library_path(state, R.home("lib"))
  }
  compile_status <- tcc_compile_string(state, source)
  if (!identical(as.integer(compile_status), 0L)) {
    stop("Rtinycc failed to compile generated Rducks wrapper", call. = FALSE)
  }
  relocate_status <- tcc_relocate(state)
  if (!identical(as.integer(relocate_status), 0L)) {
    stop("Rtinycc failed to relocate generated Rducks wrapper", call. = FALSE)
  }
  pointer <- tcc_get_symbol(state, symbol)
  if (!isTRUE(tcc_symbol_is_valid(pointer))) {
    stop("Rtinycc did not return a valid wrapper symbol", call. = FALSE)
  }

  structure(
    list(state = state, symbol = symbol, pointer = pointer, source = source),
    class = "rducks_compiled_wrapper"
  )
}

`%||%` <- function(x, y) if (is.null(x)) y else x
