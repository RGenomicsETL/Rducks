# Define an Rducks execution plan

An execution plan is connection/session policy: it says how Rducks
should marshal DuckDB chunks and what concurrency model is allowed. It
is separate from UDF registration semantics such as scalar versus
vectorized call shape, argument/return types, NULL handling, error
handling, and side effects.

## Usage

``` r
rducks_execution_plan(
  marshalling = c("arrow_r", "arrow_c", "arrow_ipc"),
  concurrency = c("serial", "inproc_concurrent", "multiprocess_parallel")
)
```

## Arguments

- marshalling:

  Chunk marshalling implementation. `"arrow_r"` uses Arrow C Data plus
  nanoarrow/R materialization and is the reference implementation.
  `"arrow_c"` uses native C/DuckDB-vector materialization for supported
  plans. `"arrow_ipc"` reserves owned Arrow IPC bytes as the future
  multiprocess transport boundary.

- concurrency:

  Concurrency contract. `"serial"` evaluates one chunk at a time in the
  calling process. `"inproc_concurrent"` allows in-process DuckDB
  callback concurrency while keeping R API work serialized on the
  recorded R execution lane. `"multiprocess_parallel"` is the future
  process-isolated chunk-parallel plan and requires
  `marshalling = "arrow_ipc"`.

## Value

An object of class `rducks_execution_plan`.

## Details

`arrow_r + serial` is the reference implementation used for conformance.
Other plans must be explicitly implemented and validated against that
reference; Rducks does not silently fall back from one plan to another.
