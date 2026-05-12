# Register an R UDF in DuckDB

Registers an R function as a DuckDB SQL function using the loaded Rducks
extension. Registration requires `external_threads=1` plus
`PRAGMA threads=1` so native registration and the default scalar
execution path stay on the calling R thread. The active
[`rducks_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_execution_plan.md)
selects and freezes the marshalling implementation for this
registration; unsupported plan/mode/type combinations fail instead of
switching engines. If a later call registers the same SQL
name/signature, the callable implementation is replaced in the shared
DuckDB database catalog rather than being tied to the registering DBI
connection. After registration, use
[`rducks_enable_inproc()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable_inproc.md)
to opt into queued same-process execution. For `arrow_ipc` plans, the
UDF closure and discovered globals are copied once to each NNG worker in
the shared provider pool and retained for that pool's lifetime.

## Usage

``` r
rducks_register(
  con,
  name,
  fun,
  args,
  returns,
  mode = "scalar",
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

  Argument type specification. Use `NULL` for a zero-argument scalar
  UDF. Otherwise use exported DuckDB-style type descriptors such as
  `INTEGER`, `DOUBLE`, `INTEGER[]`, `INTEGER[3]`, `STRUCT(a = INTEGER)`,
  or `MAP(VARCHAR, INTEGER)`.

- returns:

  Return type specification.

- mode:

  Registration mode. `"scalar"` calls the R function once per DuckDB
  row. `"vectorized"` calls the R function once per DuckDB chunk with
  one R vector/list-column per declared argument.

- null_handling:

  Either `"default"` for NULL-in/NULL-out without calling the R
  function, or `"special"` to call the R function with the declared
  type's missing-value shape for NULL inputs (for example typed `NA` for
  ordinary scalar types and `NULL` for exact/exotic, binary, and
  composite values).

- exception_handling:

  Either `"rethrow"` to report user R function errors to DuckDB, or
  `"return_null"` to turn user R function errors into SQL NULL values.
  Return type-checking and marshalling errors still abort the query.

- side_effects:

  Logical scalar. Use `TRUE` for functions with randomness, counters,
  I/O, mutation, or other side effects so DuckDB does not treat the
  function as pure.

## Value

Object of class `rducks_registration` containing the connection,
normalized signature, and registration options. The UDF remains
registered in DuckDB even if this object is discarded.
