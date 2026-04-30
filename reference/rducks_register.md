# Register an R UDF in DuckDB

Registers a scalar R function as a DuckDB SQL function using the loaded
Rducks extension and an Rtinycc-generated shape-specific C wrapper. The
current implemented path is direct main-R-thread callback execution and
requires single-thread DuckDB execution.

## Usage

``` r
rducks_register(
  con,
  name,
  fun,
  args,
  returns,
  mode = c("row", "arrow_lapply", "arrow_nanoarrow"),
  compile = TRUE,
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

  Registration mode. `"row"` is implemented now and calls the R function
  once per row through an Rtinycc wrapper. `"arrow_lapply"` and
  `"arrow_nanoarrow"` are reserved for future batch UDF paths.

- compile:

  Kept for API compatibility; must be `TRUE`.

- null_handling:

  Either `"default"` for NULL-in/NULL-out without calling the R
  function, or `"special"` to call the R function with NA-like R values
  for NULL inputs.

- exception_handling:

  Either `"rethrow"` to report R errors to DuckDB, or `"return_null"` to
  turn callback errors into SQL NULL values.

- side_effects:

  Logical scalar. Use `TRUE` for callbacks with randomness, counters,
  I/O, mutation, or other side effects so DuckDB does not treat the
  function as pure.

## Value

Object of class `rducks_registration`. Keep this object if you want to
soft-unregister the UDF later with
[`rducks_unregister()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_unregister.md).
