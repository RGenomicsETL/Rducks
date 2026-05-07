# Define an Rducks execution plan

An execution plan describes how Rducks should marshal DuckDB chunks and
what concurrency model is allowed. When stored on a connection it is the
default for future
[`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md)
calls; the selected evaluator/marshalling is frozen into each registered
UDF's database-catalog metadata. It is separate from UDF registration
semantics such as scalar versus vectorized call shape, argument/return
types, NULL handling, error handling, and side effects.

## Usage

``` r
rducks_execution_plan(
  marshalling = c("arrow_r", "arrow_c", "arrow_ipc"),
  concurrency = c("serial", "inproc_concurrent", "multiprocess_parallel"),
  future_globals = "auto",
  future_packages = NULL,
  future_seed = FALSE,
  future_stdout = FALSE,
  future_conditions = "condition",
  future_timeout = NULL,
  ipc_provider = c("future", "mirai"),
  ipc_workers = 1L,
  ipc_max_pending = 64L
)
```

## Arguments

- marshalling:

  Chunk marshalling implementation. `"arrow_r"` uses Arrow C Data plus
  nanoarrow/R materialization and is the reference implementation.
  `"arrow_c"` uses native C/DuckDB-vector materialization for supported
  scalar and vectorized registrations. `"arrow_ipc"` uses Arrow IPC
  bytes as the explicit task/result payload for the Future-based
  multiprocess path.

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
  for `arrow_ipc + multiprocess_parallel` registrations. By default
  (`future_globals = "auto"`), Rducks discovers UDF globals once at
  registration-wrapper creation and then sends explicit worker state per
  chunk, avoiding per-chunk automatic global discovery. Use
  `future_packages` for packages that workers should attach,
  `future_globals = TRUE` for Future's per-task discovery, `FALSE` for
  only Rducks' required task state, or a character vector/named list for
  explicit extra globals. `future_timeout` is also used as the Arrow IPC
  provider wait timeout. The persistent mirai provider preloads the same
  discovered globals/packages once per provider registration.

- ipc_provider:

  Worker provider for `arrow_ipc + multiprocess_parallel`. `"future"` is
  the portable default. `"mirai"` uses persistent mirai daemon workers
  and fails at registration if the `mirai` package is unavailable; it
  does not fall back to Future. The mirai provider broadcasts each
  registered UDF closure plus discovered globals/packages to every
  daemon in the shared database-runtime provider pool, so avoid
  capturing large objects in UDF environments unless that memory cost is
  intended.

- ipc_workers:

  Number of persistent workers for `ipc_provider = "mirai"`.

- ipc_max_pending:

  Maximum accepted but uncollected tasks for the persistent provider.
  The default bounds provider memory/use of outstanding callback work;
  `NULL` disables this provider-level limit.

## Value

An object of class `rducks_execution_plan`.

## Details

`arrow_r + serial` is the reference implementation used for conformance.
Other plans must be explicitly implemented and validated against that
reference; Rducks does not silently fall back from one plan to another.
Each valid pair maps to a concrete internal `engine_id` such as
`"arrow_c_direct_serial"` or `"ipc_future_pool"`; the older
`marshalling + concurrency` fields remain for user-facing readability.
