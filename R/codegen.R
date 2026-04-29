rducks_match_mode <- function(mode) {
  mode <- match.arg(mode, c("row", "arrow_lapply", "arrow_nanoarrow", "compiled"))
  if (identical(mode, "compiled")) {
    mode <- "row"
  }
  mode
}

#' Create an Rducks UDF specification
#'
#' @param name SQL function name.
#' @param fun R function.
#' @param args Character vector of Rducks type tokens.
#' @param returns Return type token.
#' @param mode Registration mode. `"row"` is implemented now and uses an
#'   Rtinycc-generated wrapper for row-oriented scalar callbacks.
#'   `"arrow_lapply"` and `"arrow_nanoarrow"` are reserved for future batch
#'   UDF paths.
#' @return Object of class `rducks_udf_spec`.
#' @export
rducks_udf_spec <- function(name, fun, args, returns, mode = c("row", "arrow_lapply", "arrow_nanoarrow", "compiled")) {
  mode <- rducks_match_mode(mode)
  if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)) {
    stop("name must be a non-empty character scalar", call. = FALSE)
  }
  if (!is.function(fun)) {
    stop("fun must be a function", call. = FALSE)
  }
  args <- rducks_types_normalize(args)
  returns <- rducks_type_normalize(returns)
  argument_type_mapping <- rducks_argument_type_mapping(args)
  structure(
    list(
      name = name,
      fun = fun,
      args = args,
      returns = returns,
      mode = mode,
      signature = rducks_duckdb_signature(name, args, returns),
      argument_type_mapping = argument_type_mapping
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

rducks_c_arg_expr <- function(arg_mapping, index) {
  if (is.character(arg_mapping)) {
    arg_mapping <- rducks_argument_type_mapping(arg_mapping)
  }
  if (!is.data.frame(arg_mapping) || nrow(arg_mapping) != 1L) {
    stop("arg_mapping must be a one-row argument type mapping", call. = FALSE)
  }
  token <- arg_mapping$rducks_type[[1L]]
  if (!identical(arg_mapping$argument_kind[[1L]], "scalar")) {
    return(sprintf(
      "arg_values[%d] = PROTECT(arg_is_null[%d] ? R_NilValue : (SEXP)args[%d]);\n  protect_count++;",
      index, index, index
    ))
  }
  protect_line <- sprintf("  protect_count++;")
  simple <- function(expr) {
    sprintf("arg_values[%d] = PROTECT(%s);\n%s", index, expr, protect_line)
  }
  switch(token,
    bool = simple(sprintf(
      "arg_is_null[%d] ? Rf_ScalarLogical(NA_LOGICAL) : Rf_ScalarLogical((*(bool *)args[%d]) ? TRUE : FALSE)",
      index, index
    )),
    i8 = simple(sprintf(
      "arg_is_null[%d] ? Rf_ScalarInteger(NA_INTEGER) : Rf_ScalarInteger((int)*(int8_t *)args[%d])",
      index, index
    )),
    u8 = simple(sprintf(
      "arg_is_null[%d] ? Rf_ScalarInteger(NA_INTEGER) : Rf_ScalarInteger((int)*(uint8_t *)args[%d])",
      index, index
    )),
    i16 = simple(sprintf(
      "arg_is_null[%d] ? Rf_ScalarInteger(NA_INTEGER) : Rf_ScalarInteger((int)*(int16_t *)args[%d])",
      index, index
    )),
    u16 = simple(sprintf(
      "arg_is_null[%d] ? Rf_ScalarInteger(NA_INTEGER) : Rf_ScalarInteger((int)*(uint16_t *)args[%d])",
      index, index
    )),
    i32 = simple(sprintf(
      "arg_is_null[%d] ? Rf_ScalarInteger(NA_INTEGER) : Rf_ScalarInteger((int)*(int32_t *)args[%d])",
      index, index
    )),
    u32 = simple(sprintf(
      "arg_is_null[%d] ? Rf_ScalarReal(NA_REAL) : Rf_ScalarReal((double)*(uint32_t *)args[%d])",
      index, index
    )),
    i64 = simple(sprintf(
      "arg_is_null[%d] ? Rf_ScalarReal(NA_REAL) : Rf_ScalarReal((double)*(int64_t *)args[%d])",
      index, index
    )),
    u64 = simple(sprintf(
      "arg_is_null[%d] ? Rf_ScalarReal(NA_REAL) : Rf_ScalarReal((double)*(uint64_t *)args[%d])",
      index, index
    )),
    f32 = simple(sprintf(
      "arg_is_null[%d] ? Rf_ScalarReal(NA_REAL) : Rf_ScalarReal((double)*(float *)args[%d])",
      index, index
    )),
    f64 = simple(sprintf(
      "arg_is_null[%d] ? Rf_ScalarReal(NA_REAL) : Rf_ScalarReal(*(double *)args[%d])",
      index, index
    )),
    varchar = simple(sprintf(
      "arg_is_null[%d] ? Rf_ScalarString(NA_STRING) : Rf_mkString(*(const char **)args[%d])",
      index, index
    )),
    blob = sprintf(paste(
      "if (arg_is_null[%d]) {",
      "  arg_values[%d] = PROTECT(R_NilValue);",
      "} else {",
      "  rducks_blob_t *blob_%d = (rducks_blob_t *)args[%d];",
      "  if (blob_%d->len > (uint64_t)R_XLEN_T_MAX) {",
      "    if (out_is_null) *out_is_null = true;",
      "    UNPROTECT(protect_count);",
      "    return false;",
      "  }",
      "  arg_values[%d] = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)blob_%d->len));",
      "  if (blob_%d->len > 0) memcpy(RAW(arg_values[%d]), blob_%d->ptr, (size_t)blob_%d->len);",
      "}",
      "protect_count++;",
      sep = "\n"
    ), index, index, index, index, index, index, index, index, index, index, index),
    date = sprintf(paste(
      "if (arg_is_null[%d]) {",
      "  arg_values[%d] = PROTECT(Rf_ScalarReal(NA_REAL));",
      "} else {",
      "  rducks_date_t *date_%d = (rducks_date_t *)args[%d];",
      "  SEXP cls_%d;",
      "  arg_values[%d] = PROTECT(Rf_ScalarReal((double)date_%d->days));",
      "  cls_%d = PROTECT(Rf_mkString(\"Date\"));",
      "  Rf_classgets(arg_values[%d], cls_%d);",
      "  UNPROTECT(1);",
      "}",
      "protect_count++;",
      sep = "\n"
    ), index, index, index, index, index, index, index, index, index, index),
    time = simple(sprintf(
      "arg_is_null[%d] ? Rf_ScalarReal(NA_REAL) : Rf_ScalarReal((double)((rducks_time_t *)args[%d])->micros / 1000000.0)",
      index, index
    )),
    timestamp = sprintf(paste(
      "if (arg_is_null[%d]) {",
      "  arg_values[%d] = PROTECT(Rf_ScalarReal(NA_REAL));",
      "} else {",
      "  rducks_timestamp_t *ts_%d = (rducks_timestamp_t *)args[%d];",
      "  SEXP cls_%d;",
      "  arg_values[%d] = PROTECT(Rf_ScalarReal((double)ts_%d->micros / 1000000.0));",
      "  cls_%d = PROTECT(Rf_allocVector(STRSXP, 2));",
      "  SET_STRING_ELT(cls_%d, 0, Rf_mkChar(\"POSIXct\"));",
      "  SET_STRING_ELT(cls_%d, 1, Rf_mkChar(\"POSIXt\"));",
      "  Rf_classgets(arg_values[%d], cls_%d);",
      "  UNPROTECT(1);",
      "}",
      "protect_count++;",
      sep = "\n"
    ), index, index, index, index, index, index, index, index, index, index, index, index),
    stop("unsupported generated argument type: ", token, call. = FALSE)
  )
}

rducks_c_integer_return_lines <- function(c_type, min_value, max_value) {
  c(
    "  double value = Rf_asReal(result);",
    "  if (ISNA(value)) {",
    "    if (out_is_null) *out_is_null = true;",
    sprintf("  } else if (!R_FINITE(value) || value < %.17g || value > %.17g) {", min_value, max_value),
    "    UNPROTECT(protect_count);",
    "    return false;",
    "  } else {",
    sprintf("    *(%s *)out_value = (%s)value;", c_type, c_type),
    "    if (out_is_null) *out_is_null = false;",
    "  }"
  )
}

rducks_c_real_return_lines <- function(c_type) {
  c(
    "  double value = Rf_asReal(result);",
    "  if (ISNA(value)) {",
    "    if (out_is_null) *out_is_null = true;",
    "  } else {",
    sprintf("    *(%s *)out_value = (%s)value;", c_type, c_type),
    "    if (out_is_null) *out_is_null = false;",
    "  }"
  )
}

rducks_c_return_lines <- function(token) {
  if (rducks_type_is_composite(token)) {
    return(c(
      "  *(SEXP *)out_value = result;",
      "  R_PreserveObject(result);",
      "  if (out_is_null) *out_is_null = false;"
    ))
  }
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
    i8 = rducks_c_integer_return_lines("int8_t", -128, 127),
    u8 = rducks_c_integer_return_lines("uint8_t", 0, 255),
    i16 = rducks_c_integer_return_lines("int16_t", -32768, 32767),
    u16 = rducks_c_integer_return_lines("uint16_t", 0, 65535),
    i32 = rducks_c_integer_return_lines("int32_t", -2147483648, 2147483647),
    u32 = rducks_c_integer_return_lines("uint32_t", 0, 4294967295),
    i64 = rducks_c_integer_return_lines("int64_t", -9223372036854775808, 9223372036854775807),
    u64 = rducks_c_integer_return_lines("uint64_t", 0, 18446744073709551615),
    f32 = rducks_c_real_return_lines("float"),
    f64 = rducks_c_real_return_lines("double"),
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
      "      const char *src = Rf_translateCharUTF8(STRING_ELT(str_vec, 0));",
      "      size_t len = strlen(src);",
      "      char *copy = (char *)malloc(len + 1U);",
      "      if (!copy) {",
      "        if (str_protected) UNPROTECT(1);",
      "        UNPROTECT(protect_count);",
      "        return false;",
      "      }",
      "      memcpy(copy, src, len + 1U);",
      "      *(char **)out_value = copy;",
      "      if (out_is_null) *out_is_null = false;",
      "    }",
      "    if (str_protected) UNPROTECT(1);",
      "  }"
    ),
    blob = c(
      "  if (TYPEOF(result) != RAWSXP) {",
      "    UNPROTECT(protect_count);",
      "    return false;",
      "  }",
      "  rducks_blob_t *blob = (rducks_blob_t *)out_value;",
      "  blob->len = (uint64_t)XLENGTH(result);",
      "  if (blob->len == 0) {",
      "    blob->ptr = NULL;",
      "  } else {",
      "    unsigned char *copy = (unsigned char *)malloc((size_t)blob->len);",
      "    if (!copy) {",
      "      UNPROTECT(protect_count);",
      "      return false;",
      "    }",
      "    memcpy(copy, RAW(result), (size_t)blob->len);",
      "    blob->ptr = copy;",
      "  }",
      "  if (out_is_null) *out_is_null = false;"
    ),
    date = c(
      "  double value = Rf_asReal(result);",
      "  if (ISNA(value)) {",
      "    if (out_is_null) *out_is_null = true;",
      "  } else if (!R_FINITE(value) || value < -2147483648.0 || value > 2147483647.0) {",
      "    UNPROTECT(protect_count);",
      "    return false;",
      "  } else {",
      "    ((rducks_date_t *)out_value)->days = (int32_t)value;",
      "    if (out_is_null) *out_is_null = false;",
      "  }"
    ),
    time = c(
      "  double value = Rf_asReal(result);",
      "  if (ISNA(value)) {",
      "    if (out_is_null) *out_is_null = true;",
      "  } else if (!R_FINITE(value)) {",
      "    UNPROTECT(protect_count);",
      "    return false;",
      "  } else {",
      "    ((rducks_time_t *)out_value)->micros = (int64_t)(value * 1000000.0);",
      "    if (out_is_null) *out_is_null = false;",
      "  }"
    ),
    timestamp = c(
      "  double value = Rf_asReal(result);",
      "  if (ISNA(value)) {",
      "    if (out_is_null) *out_is_null = true;",
      "  } else if (!R_FINITE(value)) {",
      "    UNPROTECT(protect_count);",
      "    return false;",
      "  } else {",
      "    ((rducks_timestamp_t *)out_value)->micros = (int64_t)(value * 1000000.0);",
      "    if (out_is_null) *out_is_null = false;",
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

  arg_mapping <- spec$argument_type_mapping %||% rducks_argument_type_mapping(spec$args)
  if (!identical(arg_mapping$rducks_type, spec$args)) {
    arg_mapping <- rducks_argument_type_mapping(spec$args)
  }
  arg_lines <- if (n_args) {
    vapply(seq_len(n_args), function(i) rducks_c_arg_expr(arg_mapping[i, , drop = FALSE], i - 1L), character(1))
  } else {
    character()
  }
  return_lines <- rducks_c_return_lines(spec$returns)
  result_null_check <- if (rducks_type_is_composite(spec$returns)) {
    c(
      "  if (result == R_NilValue) {",
      "    if (out_is_null) *out_is_null = true;",
      "    UNPROTECT(protect_count);",
      "    return true;",
      "  }"
    )
  } else {
    c(
      "  if (result == R_NilValue || XLENGTH(result) == 0) {",
      "    if (out_is_null) *out_is_null = true;",
      "    UNPROTECT(protect_count);",
      "    return true;",
      "  }"
    )
  }

  src <- paste(
    "#define _Complex",
    "#include <R.h>",
    "#include <Rinternals.h>",
    "#include <R_ext/Arith.h>",
    "#include <stdbool.h>",
    "#include <stdint.h>",
    "#include <stddef.h>",
    "#include <stdlib.h>",
    "#include <string.h>",
    "typedef struct rducks_blob { const unsigned char *ptr; uint64_t len; } rducks_blob_t;",
    "typedef struct rducks_date { int32_t days; } rducks_date_t;",
    "typedef struct rducks_time { int64_t micros; } rducks_time_t;",
    "typedef struct rducks_timestamp { int64_t micros; } rducks_timestamp_t;",
    "",
    sprintf("bool %s(SEXP fun, void **args, const bool *arg_is_null, void *out_value, bool *out_is_null) {", symbol),
    sprintf("  SEXP arg_values[%d];", max(n_args, 1L)),
    "  SEXP pair = R_NilValue;",
    "  SEXP call;",
    "  SEXP result;",
    "  int protect_count = 0;",
    "  int err = 0;",
    if (n_args) paste0("  ", arg_lines, collapse = "\n") else "  (void)args;\n  (void)arg_is_null;\n  (void)arg_values;",
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
    paste(result_null_check, collapse = "\n"),
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
