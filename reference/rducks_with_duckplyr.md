# Evaluate a duckplyr pipeline with dynamic Rducks scalar UDFs

Registers selected R functions as dynamic-argument Rducks scalar UDFs on
a DuckDB connection, rewrites matching calls in a captured duckplyr
expression to duckplyr's DuckDB-function escape hatch, and evaluates the
rewritten expression. This lets a duckplyr pipeline stay in DuckDB for
those calls instead of falling back to dplyr, provided every registered
function has an explicit return type.

## Usage

``` r
rducks_with_duckplyr(
  con,
  expr,
  returns,
  env = parent.frame(),
  null_handling = c("default", "special"),
  exception_handling = c("rethrow", "return_null"),
  side_effects = FALSE
)

# S3 method for class 'duckdb_connection'
with(data, expr, ..., rducks_returns, rducks_env = parent.frame())
```

## Arguments

- con:

  A `duckdb_connection` with Rducks enabled.

- expr:

  A duckplyr expression or pipeline to evaluate.

- returns:

  Named list or named character vector of return types. Names must be R
  function names visible from `env`; values are Rducks type descriptors
  or scalar type tokens, e.g. `list(score_fun = DOUBLE)`.

- env:

  Evaluation environment for `expr` and function lookup.

- null_handling, exception_handling, side_effects:

  Passed to
  [`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md).

- data:

  A `duckdb_connection` with Rducks enabled.

- ...:

  Reserved for future extensions; must be empty.

- rducks_returns:

  Named return-type list for dynamic Rducks UDFs.

- rducks_env:

  Evaluation environment for `expr` and function lookup.

## Value

The value of the evaluated expression.

## Details

This helper intentionally requires return-type declarations: DuckDB
needs a scalar function's return type during planning even when its
input arguments are accepted dynamically. Dynamic arguments are a
duckplyr-oriented convenience path that uses nanoarrow's default input
conversion. The duckplyr bridge registers these UDFs with
`mode = "scalar"`; it does not expose Rducks' vectorized chunk-call
mode. Use explicit `args` in
[`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md)
when you need Rducks' declared composite, exotic, special-NULL, or
vectorized input semantics.
