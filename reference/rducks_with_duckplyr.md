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
  side_effects = FALSE,
  mode = "scalar"
)

# S3 method for class 'duckdb_connection'
with(
  data,
  expr,
  ...,
  rducks_returns,
  rducks_env = parent.frame(),
  rducks_mode = "scalar"
)
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
  [`rducks_register_scalar_udf()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_register_scalar_udf.md).

- mode:

  Rducks scalar-UDF evaluation mode for registered helpers. `"scalar"`
  calls the R helper once per row; `"vectorized"` calls it once per
  DuckDB chunk and requires a vectorized helper.

- data:

  A `duckdb_connection` with Rducks enabled.

- ...:

  Reserved for future extensions; must be empty.

- rducks_returns:

  Named return-type list for dynamic Rducks UDFs.

- rducks_env:

  Evaluation environment for `expr` and function lookup.

- rducks_mode:

  Rducks scalar-UDF evaluation mode for helpers registered through
  `with.duckdb_connection()`.

## Value

The value of the evaluated expression.

## Details

This helper intentionally requires return-type declarations: DuckDB
needs a scalar function's return type during planning even when its
input arguments are accepted dynamically. Dynamic arguments are a
duckplyr-oriented convenience path that uses Rducks' direct
DuckDB-vector input conversion. The duckplyr bridge defaults to
`mode = "scalar"` because ordinary R calls in duckplyr SQL expressions
are written as row-wise scalar functions. Set `mode = "vectorized"` only
for helpers that accept full vectors/chunks and return a vector of the
same length. The selected Rducks execution plan is still taken from
`con`, so the in-process plan from
[`rducks_execution_plan()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_execution_plan.md)
applies; set it with
[`rducks_set_execution_plan()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_set_execution_plan.md)
before evaluating the duckplyr expression. Use explicit `args` in
[`rducks_register_scalar_udf()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_register_scalar_udf.md)
when you need Rducks' declared composite, exotic, or special-NULL input
semantics.

## Examples

``` r
# \donttest{
if (requireNamespace("duckplyr", quietly = TRUE)) {
  library(dplyr)
  db <- duckdb::dbConnect(duckdb::duckdb(config = rducks_duckdb_config(list(threads = "2"))))
  rducks_enable(db, threads = "single")
  DBI::dbWriteTable(db, "scores", data.frame(x = c(1, 2, 3)))
  scores <- duckplyr::read_sql_duckdb("SELECT * FROM scores", con = db, prudence = "stingy")
  plus_one <- function(x) as.double(x + 1)
  rducks_with_duckplyr(
    db,
    scores |> mutate(y = plus_one(x)) |> collect(),
    returns = list(plus_one = DOUBLE)
  )
  rducks_release(db)
  DBI::dbDisconnect(db)
}
#> 
#> Attaching package: ‘dplyr’
#> The following objects are masked from ‘package:stats’:
#> 
#>     filter, lag
#> The following objects are masked from ‘package:base’:
#> 
#>     intersect, setdiff, setequal, union
#> duckdb keeps downloaded extensions and secrets in a temporary directory:
#> ℹ /tmp/RtmpNxox63/duckdb
#> This is removed when the R session ends.
#> • Extensions are re-downloaded each session.
#> • Secrets are lost.
#> ℹ Run duckdb(shared_home = TRUE) (or create ~/.duckdb) to keep them (suitable for most users).
#> ℹ Run duckdb(shared_home = FALSE) to accept the temporary directory (and silence this message).
#> ℹ See ?duckdb_storage for details and alternatives.
# }
```
