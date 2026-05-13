# Register an R aggregate function in DuckDB

Registers an R-backed DuckDB aggregate. The aggregate state is an
arbitrary R object, not a serialized `raw` vector. Rducks stores a
preserved reference to the state object inside the native DuckDB
aggregate state and passes that same object back to later R callbacks.
Returning `NULL` means "empty/no state"; use a wrapper such as
`list(value = NULL)` if `NULL` itself must be represented as a non-empty
state.

## Usage

``` r
rducks_register_aggregate(
  con,
  name,
  update = NULL,
  finalize = NULL,
  args,
  returns,
  combine = NULL,
  null_handling = c("default", "special"),
  copy = NULL,
  copy_chunk = NULL,
  update_chunk = NULL,
  combine_chunk = NULL,
  finalize_chunk = NULL
)
```

## Arguments

- con:

  A `duckdb_connection`.

- name:

  SQL aggregate function name.

- update:

  Optional row-wise R function called as `update(state, ...)`; may
  return any R object state or `NULL`.

- finalize:

  Optional row-wise R function called as `finalize(state)`; must return
  a scalar compatible with `returns` or `NULL` for SQL `NULL`.

- args:

  Input type specification. Use exported DuckDB-style descriptors such
  as `INTEGER`, `DOUBLE`, or `VARCHAR`.

- returns:

  Return type specification.

- combine:

  Optional R function called as `combine(left, right)` when two
  non-`NULL` partial states must be merged. It may return any R object
  state or `NULL`.

- null_handling:

  Either `"default"` to skip rows with top-level NULL inputs, or
  `"special"` to pass missing values to update callbacks.

- copy:

  Optional R function called as `copy(state)` when DuckDB needs to place
  a non-`NULL` partial state into an empty target state during combine.
  When omitted, Rducks preserves another reference to the same R object.

- copy_chunk:

  Optional vectorized R function called as `copy_chunk(states)` with a
  list of states to copy. It must return a list of replacement states of
  the same length. It takes precedence over `copy()`.

- update_chunk:

  Optional vectorized R function called as
  `update_chunk(states, group_id, ...)`, where `states` is a list of
  current R state objects, `group_id` maps each input row to an element
  of `states`, and the remaining arguments are full R input vectors. It
  must return a list of replacement states with the same length as
  `states`.

- combine_chunk:

  Optional vectorized R function called as
  `combine_chunk(left_states, right_states)`, where both arguments are
  lists of R state objects or `NULL`. It must return a list of states of
  the same length.

- finalize_chunk:

  Optional vectorized R function called as `finalize_chunk(states)`,
  where `states` is a list of R state objects or `NULL`. It must return
  one result per state as either a vector or list.

## Value

Object of class `rducks_aggregate_registration` containing the
connection and normalized aggregate signature. The aggregate remains
registered in DuckDB even if this object is discarded.

## Details

The row-wise API calls `update(state, ...)` for each selected input row
and `finalize(state)` for each output state. The vectorized update API
calls `update_chunk(states, group_id, ...)` once per DuckDB input chunk.
`states` is a list of the distinct aggregate-state objects referenced by
that chunk, and `group_id` is an integer vector with one entry per input
row: `0L` means the row was skipped by default NULL handling, otherwise
the value is a one-based index into `states`. The remaining arguments
are full, unsliced R vectors for the aggregate inputs. `update_chunk()`
must return a list of replacement states with the same length as
`states`. `combine_chunk(left, right)` receives lists of state objects
for partial-state merging and must return a list with one merged state
per pair. `finalize_chunk(states)` must return a vector or list with one
scalar result per output state. Chunk callbacks take precedence over
row-wise callbacks.

This API is deliberately serialized. Registration requires
`rducks_enable(con, threads = "single")` or equivalent
`external_threads=1` plus `PRAGMA threads=1`, and execution rejects
attempts to call R from non-calling DuckDB worker threads. If DuckDB
combines partial states and the target state is empty, Rducks preserves
another reference to the source R object rather than serializing or
deep-copying it. Use `copy` or `copy_chunk` when empty-target combine
must create independent mutable state. Merging two non-`NULL` states
requires either `combine(left, right)` or `combine_chunk(left, right)`
and must still run on the recorded R thread.

With `null_handling = "default"`, rows with any top-level SQL `NULL`
input do not call [`update()`](https://rdrr.io/r/stats/update.html) or
appear in a positive `group_id` entry for `update_chunk()`. Groups with
no non-NULL rows therefore pass `NULL` to `finalize()` or
`finalize_chunk()`. With `null_handling = "special"`, update callbacks
receive the declared type's R missing-value shape for NULL inputs.
