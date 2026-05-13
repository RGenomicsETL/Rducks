# Register an R aggregate function in DuckDB

Registers an R-backed DuckDB aggregate. The aggregate state stored
inside DuckDB is native memory containing bytes from an R `raw` vector,
never an R object pointer. For each non-NULL input row, Rducks calls
`update(state, ...)`, where `state` is the previous raw state or `NULL`
and `...` are the row's scalar input values.
[`update()`](https://rdrr.io/r/stats/update.html) must return the next
raw state or `NULL`. At finalization Rducks calls `finalize(state)` and
marshals that scalar result to the declared DuckDB return type.

## Usage

``` r
rducks_register_aggregate(
  con,
  name,
  update,
  finalize,
  args,
  returns,
  combine = NULL,
  null_handling = c("default", "special")
)
```

## Arguments

- con:

  A `duckdb_connection`.

- name:

  SQL aggregate function name.

- update:

  R function called as `update(state, ...)`; must return a raw vector
  state or `NULL`.

- finalize:

  R function called as `finalize(state)`; must return a scalar
  compatible with `returns` or `NULL` for SQL `NULL`.

- args:

  Input type specification. Use exported DuckDB-style descriptors such
  as `INTEGER`, `DOUBLE`, or `VARCHAR`.

- returns:

  Return type specification.

- combine:

  Optional R function called as `combine(left, right)` when two
  non-empty partial raw states must be merged. It must return a raw
  vector state or `NULL`.

- null_handling:

  Either `"default"` to skip rows with top-level NULL inputs, or
  `"special"` to pass missing values to
  [`update()`](https://rdrr.io/r/stats/update.html).

## Value

Object of class `rducks_aggregate_registration` containing the
connection and normalized aggregate signature. The aggregate remains
registered in DuckDB even if this object is discarded.

## Details

This API is deliberately serialized. Registration requires
`rducks_enable(con, threads = "single")` or equivalent
`external_threads=1` plus `PRAGMA threads=1`, and execution rejects
attempts to call R from non-calling DuckDB worker threads. If DuckDB
combines partial states, Rducks can copy a source state into an empty
target; merging two non-empty states requires `combine(left, right)` and
must still run on the recorded R thread. Cross-thread R aggregate
execution is future work.

With `null_handling = "default"`, rows with any top-level SQL `NULL`
input do not call [`update()`](https://rdrr.io/r/stats/update.html).
Groups with no non-NULL rows therefore pass `NULL` to `finalize()`. With
`null_handling = "special"`,
[`update()`](https://rdrr.io/r/stats/update.html) receives the declared
type's R missing-value shape for NULL inputs.
