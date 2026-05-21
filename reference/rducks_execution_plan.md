# Define an Rducks execution plan

An execution plan describes how Rducks should marshal DuckDB chunks and
what concurrency model is allowed. When stored on a connection it is the
default for future
[`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md)
calls and updates the native runtime backend used for matching
concurrent execution; the selected evaluator/marshalling is frozen into
each registered scalar UDF's database-catalog metadata. It is separate
from DuckDB function kind and from scalar-UDF registration semantics
such as Rducks evaluation mode (`"scalar"` row calls versus
`"vectorized"` chunk calls), argument/return types, NULL handling, error
handling, and side effects.

## Usage

``` r
rducks_execution_plan(
  marshalling = c("arrow_r", "arrow_c", "arrow_ipc"),
  concurrency = c("serial", "inproc_concurrent", "multiprocess_parallel"),
  ipc_globals = "auto",
  ipc_packages = NULL,
  ipc_timeout = NULL,
  ipc_endpoints = NULL,
  ipc_transport = NULL,
  ipc_globals_share = "none",
  ipc_provider = "nng",
  ipc_workers = 1L,
  ipc_max_pending = 64L
)
```

## Arguments

- marshalling:

  Chunk marshalling implementation. `"arrow_r"` uses Arrow C Data plus
  nanoarrow/R materialization and is the reference implementation.
  `"arrow_c"` uses native C/DuckDB-vector materialization for supported
  scalar-UDF evaluation modes. `"arrow_ipc"` uses Arrow IPC bytes as the
  explicit task/result payload for the NNG multiprocess path.

- concurrency:

  Concurrency contract. `"serial"` evaluates one chunk at a time in the
  calling process. `"inproc_concurrent"` allows in-process DuckDB
  callback concurrency while keeping R API work serialized on the
  recorded main R thread. `"multiprocess_parallel"` uses persistent
  NNG/nanonext workers for process-isolated chunk work and requires
  `marshalling = "arrow_ipc"`. When `ipc_endpoints` is `NULL`, Rducks
  starts local worker loops with mirai daemons; otherwise the endpoint
  URLs are passed through unchanged.

- ipc_globals, ipc_packages, ipc_timeout, ipc_endpoints, ipc_transport:

  Arrow IPC worker options. By default (`ipc_globals = "auto"`), Rducks
  discovers scalar-UDF globals once at registration-wrapper creation and
  broadcasts them to each NNG worker when the scalar UDF is registered
  with the shared provider pool. Automatic capture estimates the
  serialized globals payload and warns when it exceeds option
  `rducks.ipc_globals.warn_bytes` (8 MiB by default); option
  `rducks.ipc_globals.max_bytes` can set a hard byte limit. Set
  `ipc_globals_share = "mori"` to pass selected globals through mori
  shared memory references for same-host workers; Rducks keeps the
  shared objects anchored for the registered scalar UDF lifetime. Use
  `ipc_packages` for packages that workers should attach,
  `ipc_globals = FALSE` to rely only on the serialized UDF closure and
  explicit task state, or a character vector / named list for explicit
  extra globals. `ipc_timeout` is the positive finite provider wait
  timeout in seconds; `NULL` uses a finite default of 30 seconds.
  `ipc_endpoints` optionally supplies NNG endpoint URLs for worker
  processes that the caller starts and stops; those processes must run
  the Rducks NNG worker loop. Any NNG URL transport supported by both
  endpoints is allowed. When endpoints are not supplied, `ipc_transport`
  selects the transport used for the mirai-launched local worker
  endpoints and must be left as `NULL` when explicit `ipc_endpoints` are
  supplied. Rducks retries local TCP/WebSocket startup with fresh
  endpoint bundles after startup-ping failure; caller-supplied endpoints
  remain caller-owned and fail fast. `"abstract"` means Linux abstract
  IPC, `"ipc"` means NNG IPC (Unix-domain sockets on POSIX and named
  pipes on Windows), `"unix"` means the POSIX Unix-domain alias, and
  `"tcp"` / `"ws"` use loopback TCP / WebSocket endpoints. The default
  is `"abstract"` on Linux and `"ipc"` elsewhere.

- ipc_globals_share:

  How selected IPC globals are represented before worker broadcast.
  `"none"` serializes them into the registration payload. `"mori"`
  applies
  [`mori::share()`](https://shikokuchuo.net/mori/reference/share.html)
  to each selected global before serialization, which can turn large
  atomic vectors, lists, and data frames into same-host shared-memory
  references. This requires the optional mori package and workers on the
  same machine.

- ipc_provider:

  Worker provider for `arrow_ipc + multiprocess_parallel`. Only `"nng"`
  is supported. The NNG provider broadcasts each registered scalar UDF
  closure plus discovered globals/packages to every worker in the shared
  database-runtime provider pool, so avoid capturing large objects in
  UDF environments unless that memory cost is intended or
  `ipc_globals_share = "mori"` is appropriate.

- ipc_workers:

  Number of persistent NNG workers.

- ipc_max_pending:

  Maximum simultaneous native NNG requests admitted per registered
  scalar-UDF client pool. `NULL` uses the provider default of 64.
  Non-IPC plans store `NA_integer_` for this field. The current provider
  still uses synchronous request/reply per callback rather than
  collect-many batching, but this value is enforced as a bounded
  pending/in-flight guard before a callback enters the native request
  path.

## Value

An object of class `rducks_execution_plan`.

## Details

`arrow_r + serial` is the reference implementation used for conformance.
Other plans must be explicitly implemented and validated against that
reference; Rducks does not silently switch from one plan to another.
`arrow_ipc + multiprocess_parallel` uses the native NNG path with
vendored nanoarrow C/IPC encoding. Each valid pair maps to a concrete
internal `engine_id` such as `"arrow_c_direct_serial"` or
`"ipc_nng_pool"`.

## Examples

``` r
rducks_execution_plan("arrow_r", "serial")
#> <rducks_execution_plan>
#>   plan_id:     arrow_r+serial
#>   engine_id:   arrow_r_serial
#>   marshalling: arrow_r
#>   concurrency: serial
#>   reference:   yes
#>   implemented: yes
#>   call shapes: scalar, vectorized
rducks_execution_plan("arrow_c", "inproc_concurrent")
#> <rducks_execution_plan>
#>   plan_id:     arrow_c+inproc_concurrent
#>   engine_id:   arrow_c_direct_main_queue
#>   marshalling: arrow_c
#>   concurrency: inproc_concurrent
#>   reference:   no
#>   implemented: yes
#>   call shapes: scalar, vectorized
```
