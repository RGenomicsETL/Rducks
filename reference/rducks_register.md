# Register an R UDF in DuckDB

Registers an R function as a DuckDB SQL function using the loaded Rducks
extension. Registration requires `external_threads=1` plus
`PRAGMA threads=1` so native registration and the default scalar
execution path stay on the calling R thread. After registration, use
[`rducks_enable_inproc()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable_inproc.md)
to opt into queued same-process execution.

## Usage

``` r
rducks_register(
  con,
  name,
  fun,
  args,
  returns,
  mode = "scalar",
  eval_mode = c("R", "RC"),
  null_handling = c("default", "special"),
  exception_handling = c("rethrow", "return_null"),
  side_effects = FALSE
)
```

## Arguments

- con:

  A `duckdb_connection`.

- name:

  SQL function name.

- fun:

  R function.

- args:

  Argument type specification. Use exported DuckDB-style type objects
  such as `INTEGER`, `DOUBLE`, `INTEGER[]`, `INTEGER[3]`,
  `STRUCT(a = INTEGER)`, or `MAP(VARCHAR, INTEGER)`.

- returns:

  Return type specification.

- mode:

  Registration mode. `"scalar"` calls the R function once per DuckDB
  row. `"vectorized"` calls the R function once per DuckDB chunk with
  one R vector/list-column per declared argument.

- eval_mode:

  Scalar evaluator implementation. `"R"` uses the R/nanoarrow adapter;
  `"RC"` uses the native C row-loop adapter and validates against the
  same scalar-mode semantics. `mode = "vectorized"` currently supports
  `eval_mode = "R"` only.

- null_handling:

  Either `"default"` for NULL-in/NULL-out without calling the R
  function, or `"special"` to call the R function with the declared
  type's missing-value shape for NULL inputs (for example typed `NA` for
  ordinary scalar types and `NULL` for exact/exotic, binary, and
  composite values).

- exception_handling:

  Either `"rethrow"` to report R errors to DuckDB, or `"return_null"` to
  turn R errors into SQL NULL values.

- side_effects:

  Logical scalar. Use `TRUE` for functions with randomness, counters,
  I/O, mutation, or other side effects so DuckDB does not treat the
  function as pure.

## Value

Object of class `rducks_registration` containing the connection,
normalized signature, and registration options. The UDF remains
registered in DuckDB even if this object is discarded.
