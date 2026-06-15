# Define an Rducks execution plan

An execution plan describes where Rducks evaluates registered scalar-UDF
chunks: in the current R process (`transport = "inproc"`) or in
persistent worker R processes (`transport = "ipc"`). When stored on a
connection it is the default for future
[`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md)
calls and updates the native runtime backend used for matching
concurrent execution; the resolved transport metadata is frozen into
each registered scalar UDF's database-catalog metadata. It is separate
from DuckDB function kind and from scalar-UDF registration semantics
such as Rducks evaluation mode (`"scalar"` row calls versus
`"vectorized"` chunk calls), argument/return types, NULL handling, error
handling, and side effects.

## Usage

``` r
rducks_execution_plan(
  transport = "inproc",
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

- transport:

  Placement/transport. `"inproc"` evaluates in the current R process
  with the in-process queued backend. `"ipc"` evaluates in persistent
  worker R processes over NNG; when `ipc_endpoints` is `NULL`, Rducks
  starts local worker loops with mirai daemons.

- ipc_globals, ipc_packages, ipc_timeout, ipc_endpoints, ipc_transport:

  IPC worker options (used when `transport = "ipc"`). By default
  (`ipc_globals = "auto"`), Rducks discovers scalar-UDF globals once at
  registration-wrapper creation and broadcasts them to each NNG worker
  when the scalar UDF is registered with the shared provider pool.
  Automatic capture estimates the serialized globals payload and warns
  when it exceeds option `rducks.ipc_globals.warn_bytes` (8 MiB by
  default); option `rducks.ipc_globals.max_bytes` can set a hard byte
  limit. Set `ipc_globals_share = "mori"` to pass selected globals
  through mori shared memory references for same-host workers; Rducks
  keeps the shared objects anchored for the registered scalar UDF
  lifetime. Use `ipc_packages` for packages that workers should attach,
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

  Worker provider for `transport = "ipc"`. Only `"nng"` is supported.
  The NNG provider broadcasts each registered scalar UDF closure plus
  discovered globals/packages to every worker in the shared
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

`"inproc"` keeps all R API work serialized on the recorded main R thread
while allowing DuckDB callback concurrency; DuckDB vectors are
materialized to SEXPs directly in extension C with no intermediate
columnar format. It maps to the internal `"direct_main_queue"` engine.

`"ipc"` uses persistent NNG/nanonext worker R processes that exchange
Quack-style binary chunk payloads (a DuckDB BinarySerializer subset):
the extension encodes each input chunk to wire bytes, the worker decodes
them, runs the R function, and returns wire-encoded results that the
extension writes back to DuckDB. Worker-process types currently cover
fixed-width scalars, `VARCHAR`/`BLOB`, `DECIMAL`, `INTERVAL`, `ENUM`,
`BIT`, `GEOMETRY`, `MAP`, `UNION`, and `LIST`/`ARRAY`/`STRUCT` of
supported types; `VARIANT` is rejected at registration until the native
bridge covers it. It maps to the internal `"ipc_nng_pool"` engine.

## Examples

``` r
rducks_execution_plan("inproc")
#> <rducks_execution_plan>
#>   plan_id:     direct+inproc_concurrent
#>   engine_id:   direct_main_queue
#>   transport:   inproc
#>   concurrency: inproc_concurrent
#>   reference:   no
#>   implemented: yes
#>   call shapes: scalar, vectorized
```
