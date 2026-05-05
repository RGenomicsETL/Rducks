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
  concurrency = c("serial", "inproc_concurrent", "multiprocess_parallel"),
  future_globals = TRUE,
  future_packages = NULL,
  future_seed = FALSE,
  future_stdout = FALSE,
  future_conditions = "condition",
  future_timeout = NULL
)
```

## Arguments

- marshalling:

  Chunk marshalling implementation. `"arrow_r"` uses Arrow C Data plus
  nanoarrow/R materialization and is the reference implementation.
  `"arrow_c"` uses native C/DuckDB-vector materialization for supported
  plans. `"arrow_ipc"` uses Arrow IPC bytes as the explicit task/result
  payload for the Future-based multiprocess path.

- concurrency:

  Concurrency contract. `"serial"` evaluates one chunk at a time in the
  calling process. `"inproc_concurrent"` allows in-process DuckDB
  callback concurrency while keeping R API work serialized on the
  recorded main R thread. `"multiprocess_parallel"` uses the current
  `future` backend for process-isolated chunk work and requires
  `marshalling = "arrow_ipc"`.

- future_globals, future_packages, future_seed, future_stdout,
  future_conditions, future_timeout:

  Options forwarded to
  [`future::future()`](https://future.futureverse.org/reference/future.html)
  for `arrow_ipc + multiprocess_parallel` registrations. Use
  `future_packages` for packages that workers should attach and
  `future_globals` when automatic global capture needs help.

## Value

An object of class `rducks_execution_plan`.

## Details

`arrow_r + serial` is the reference implementation used for conformance.
Other plans must be explicitly implemented and validated against that
reference; Rducks does not silently fall back from one plan to another.
