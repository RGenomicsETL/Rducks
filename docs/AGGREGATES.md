# R-backed aggregate functions

`rducks_register_aggregate()` is the first Rducks aggregate-function slice. It is
separate from scalar/vectorized UDF execution plans because aggregate functions
have state, update, combine, and finalize phases.

## State contract

The DuckDB aggregate state contains only native bytes:

- `update(state, ...)` receives the current state as an R `raw` vector, or
  `NULL` if no state has been produced yet.
- `update()` must return the next state as an R `raw` vector, or `NULL`.
- `combine(left, right)`, when supplied, receives two raw states (or `NULL`) and
  must return the merged raw state or `NULL`.
- `finalize(state)` receives the final raw state or `NULL` and returns a scalar
  compatible with the declared return type.

Rducks copies returned raw vectors into DuckDB-owned aggregate memory. It does
not store R object pointers inside aggregate state.

## NULLs

With `null_handling = "default"`, rows with any top-level SQL `NULL` input do not
call `update()`. A group with zero non-NULL input rows therefore calls
`finalize(NULL)`.

With `null_handling = "special"`, `update()` is called for NULL-containing rows
and receives the declared type's R missing-value shape.

## Threading and combine behavior

This slice is serialized. Register aggregates after
`rducks_enable(con, threads = "single")` or equivalent `external_threads=1` plus
`PRAGMA threads=1`. If execution reaches a DuckDB worker thread and would need
to call R, Rducks raises a DuckDB error.

When DuckDB combines partial states, Rducks may copy a source state into an empty
target without calling R. Merging two non-empty states requires a user-supplied
`combine(left, right)` function and must still happen on the recorded R thread.
Parallel R aggregate execution needs a future worker-safe state-serialization
plan before it can be enabled.
