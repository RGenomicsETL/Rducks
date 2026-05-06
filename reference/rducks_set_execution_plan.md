# Set the Rducks execution plan for a connection

Stores the R-side default execution plan used by subsequent
[`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md)
calls through this connection and updates the native runtime backend
needed by that plan. Registration still defines UDF semantics such as
scalar versus vectorized call shape, declared types, NULL handling,
error handling, and side effects. The selected evaluator/marshalling for
an already-registered UDF remains frozen in its database-catalog
metadata.

## Usage

``` r
rducks_set_execution_plan(
  con,
  plan = rducks_execution_plan(),
  threads = NULL,
  external_threads = NULL
)
```

## Arguments

- con:

  A `duckdb_connection` already enabled with
  [`rducks_enable()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable.md).

- plan:

  An
  [`rducks_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_execution_plan.md)
  object.

- threads:

  Optional positive integer to set with `PRAGMA threads`.

- external_threads:

  Optional positive integer to set with `SET external_threads`. Use
  `NULL` to restore/keep the previous setting after Rducks briefly
  forces single-thread SQL execution to update its native backend on the
  recorded main R thread. For actual DuckDB worker concurrency, keep
  this smaller than `threads`.

## Value

`con`, invisibly.

## Details

Compatibility note: the older
[`rducks_enable_inproc()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable_inproc.md)
and
[`rducks_disable_inproc()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_disable_inproc.md)
helpers now set the `inproc_concurrent` and `serial` concurrency parts
of this plan while preserving the current marshalling choice.
