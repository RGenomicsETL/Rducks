# R-backed aggregate functions

`rducks_register_aggregate()` is the Rducks aggregate-function API. It is
separate from DuckDB scalar UDF registration and scalar-UDF execution plans
because aggregate functions have state, update, combine, copy, and finalize
phases.

## State contract

The DuckDB aggregate state stores a native handle to an R object preserved by
Rducks:

- `update(state, ...)` receives the current R state object, or `NULL` if no state
  has been produced yet.
- `update()` may return any replacement R state object, or `NULL` for empty/no
  state.
- `combine(left, right)`, when supplied, receives two R state objects (or
  `NULL`) and must return the merged R state object or `NULL`.
- `copy(state)`, when supplied, creates an independent replacement state when
  DuckDB needs to copy a non-empty state into an empty target during combine.
- `finalize(state)` receives the final R state object or `NULL` and returns a
  scalar compatible with the declared return type.

Optional chunk callbacks operate on lists of state objects:
`update_chunk(states, group_id, ...)`, `combine_chunk(left_states,
right_states)`, `copy_chunk(states)`, and `finalize_chunk(states)`. Chunk
callbacks take precedence over row-wise callbacks when supplied.

`NULL` is reserved for empty/no state. Use a wrapper such as `list(value = NULL)`
if `NULL` itself must be represented as a non-empty state.

## NULLs

With `null_handling = "default"`, rows with any top-level SQL `NULL` input do not
call `update()` and appear as `group_id == 0L` for `update_chunk()`. A group with
zero non-NULL input rows therefore calls `finalize(NULL)` or passes `NULL` in the
chunk finalization state list.

With `null_handling = "special"`, update callbacks are called for NULL-containing
rows and receive the declared type's R missing-value shape.

## Threading and combine behavior

This API is serialized. Register aggregates after
`rducks_enable(con, threads = "single")` or equivalent `external_threads=1` plus
`PRAGMA threads=1`. If execution reaches a DuckDB worker thread and would need
to call R, Rducks raises a DuckDB error.

When DuckDB combines partial states into an empty target and no `copy()` /
`copy_chunk()` callback is supplied, Rducks preserves another reference to the
same R object. Merging two non-`NULL` states requires a user-supplied
`combine(left, right)` or `combine_chunk(left_states, right_states)` callback and
must still happen on the recorded R thread.
