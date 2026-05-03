# Set the Rducks execution plan for a connection

Sets connection/session policy for Rducks chunk execution. Registration
still defines UDF semantics such as scalar versus vectorized call shape,
declared types, NULL handling, error handling, and side effects. The
execution plan chooses the marshalling implementation and concurrency
contract.

## Usage

``` r
rducks_set_execution_plan(
  con,
  plan = rducks_execution_plan(),
  threads = NULL,
  external_threads = threads
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

  Optional positive integer to set with `SET external_threads`. Defaults
  to `threads`.

## Value

`con`, invisibly.

## Details

Compatibility note: the older
[`rducks_enable_inproc()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable_inproc.md)
and
[`rducks_disable_inproc()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_disable_inproc.md)
helpers now set the `inproc_concurrent` and `serial` concurrency parts
of this plan while preserving the current marshalling choice.
