# Register an R-backed DuckDB scalar UDF

Registers an R function as a DuckDB scalar SQL function using the loaded
Rducks extension. In DuckDB terminology this is a scalar UDF: it returns
one SQL value for each logical input row. The `mode` argument is Rducks'
evaluation mode for that scalar UDF, not a DuckDB function kind:
`"scalar"` calls the R function once per logical row, while
`"vectorized"` calls the R function once per DuckDB chunk with
vector/list-column inputs.

## Usage

``` r
rducks_register_scalar_udf(
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

  Optional argument type specification. If omitted, Rducks registers a
  dynamic-varargs DuckDB scalar function. DuckDB resolves the concrete
  argument logical types at bind time, and Rducks materializes those
  inputs with the same typed semantics used for an explicit `args = ...`
  signature across scalar/vectorized evaluation and supported `arrow_r`,
  `arrow_c`, and `arrow_ipc` execution plans. Use explicit `NULL` for a
  zero-argument scalar UDF. Otherwise use exported DuckDB-style type
  descriptors such as `INTEGER`, `DOUBLE`, `INTEGER[]`, `INTEGER[3]`,
  `STRUCT(a = INTEGER)`, or `MAP(VARCHAR, INTEGER)`.

- returns:

  Return type specification.

- mode:

  Rducks evaluation mode for this DuckDB scalar UDF. `"scalar"` calls
  the R function once per DuckDB row. `"vectorized"` calls the R
  function once per DuckDB chunk with one R vector/list-column per
  declared or dynamically bound argument.

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

Object of class `rducks_scalar_udf_registration` containing the
connection, normalized signature, and registration options. The scalar
UDF remains registered in DuckDB even if this object is discarded.

## Details

Registration requires `external_threads=1` plus `PRAGMA threads=1` so
native registration and the default scalar evaluation path stay on the
calling R thread. The active
[`rducks_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_execution_plan.md)
selects and freezes the marshalling/concurrency implementation for this
registration; unsupported plan/evaluation-mode/type combinations fail
instead of switching engines. If a later call registers the same SQL
name/signature, the callable implementation is replaced in the shared
DuckDB database catalog rather than being tied to the registering DBI
connection. Choose the desired execution plan before registration with
[`rducks_set_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_set_execution_plan.md);
the selected evaluator/marshalling metadata is then stored with the
native catalog entry. R-backed UDF registrations are live DuckDB-runtime
catalog entries, not durable schema objects: they are visible to sibling
connections while the same DuckDB database runtime remains open, but a
file-backed database must be enabled and registered again after it is
fully closed and reopened. For `arrow_ipc` plans, the UDF closure and
discovered globals are copied once to each NNG worker in the shared
provider pool and retained for that pool's lifetime.
