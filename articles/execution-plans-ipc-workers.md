# Execution Plans and IPC Workers

Execution plans apply to DuckDB scalar UDFs. They choose how DuckDB
chunks are marshalled to R and what concurrency contract is allowed.

## Supported plan families

- `arrow_r + serial`: reference path through DuckDB Arrow C Data and
  nanoarrow/R materialization.
- `arrow_c + serial`: native C materialization for the supported
  scalar-UDF type subset.
- `arrow_r + inproc_concurrent` and `arrow_c + inproc_concurrent`:
  DuckDB worker callbacks can submit synchronous work to the
  extension-owned in-process queue, but all R API work still runs on the
  recorded R thread.
- `arrow_ipc + multiprocess_parallel`: native NNG request/reply
  transport with Arrow IPC request/result bytes and persistent R worker
  processes.

Unsupported combinations fail. Rducks does not silently fall back from
one engine to another.

``` r

library(DBI)
library(duckdb)
library(Rducks)

con <- dbConnect(duckdb(config = list(allow_unsigned_extensions = "true")))
rducks_enable(con, threads = "single")
```

## Select the plan before registration

The default execution plan stored on a connection is used for future
scalar-UDF registrations. Register UDFs under the plan you want to test
or deploy.

``` r

rducks_set_execution_plan(
  con,
  rducks_execution_plan("arrow_c", "serial")
)

rducks_register_scalar_udf(
  con,
  name = "r_plus_one_c",
  fun = function(x) x + 1L,
  args = INTEGER,
  returns = INTEGER
)
#> <rducks_scalar_udf_registration>
#>   registered:      yes
#>   name:            r_plus_one_c
#>   evaluation_mode: scalar
#>   plan:            arrow_c+serial
#>   signature:       r_plus_one_c(INTEGER) -> INTEGER
```

For concurrent execution demonstrations, set the matching plan again
before query execution so the native runtime backend and DuckDB thread
settings match the UDF metadata being exercised.

``` r

rducks_set_execution_plan(
  con,
  rducks_execution_plan("arrow_c", "inproc_concurrent"),
  threads = 4L,
  external_threads = 4L
)
```

## Arrow IPC worker plan

`arrow_ipc + multiprocess_parallel` starts or connects to persistent R
workers that receive Arrow IPC-encoded chunks over NNG. Registration
still happens under single-thread DuckDB settings; widen `threads` /
`external_threads` afterwards for query execution. This vignette uses
loopback TCP for the local NNG transport because it is the most portable
choice for executed documentation builds; local IPC transports such as
`"ipc"`, `"unix"`, or Linux `"abstract"` remain available when supported
by the host. Windows documentation builds also use a longer
startup/register timeout because worker process startup can be slower
there.

``` r

ipc_workers <- 1L
ipc_transport <- "tcp"
ipc_timeout <- if (identical(Sys.info()[["sysname"]], "Windows")) 120 else 30

ipc_available <- TRUE
ipc_start_error <- NULL
tryCatch({
  rducks_set_execution_plan(
    con,
    rducks_execution_plan(
      "arrow_ipc",
      "multiprocess_parallel",
      ipc_workers = ipc_workers,
      ipc_transport = ipc_transport,
      ipc_timeout = ipc_timeout
    ),
    threads = 1L,
    external_threads = 1L
  )

  rducks_register_scalar_udf(
    con,
    name = "r_slow_square",
    fun = function(x) {
      Sys.sleep(0.1)
      x * x
    },
    args = DOUBLE,
    returns = DOUBLE,
    mode = "vectorized",
    side_effects = TRUE
  )

  rducks_set_execution_plan(
    con,
    rducks_execution_plan(
      "arrow_ipc",
      "multiprocess_parallel",
      ipc_workers = ipc_workers,
      ipc_transport = ipc_transport,
      ipc_timeout = ipc_timeout
    ),
    threads = ipc_workers + 1L,
    external_threads = ipc_workers
  )
}, error = function(e) {
  ipc_available <<- FALSE
  ipc_start_error <<- conditionMessage(e)
  message("IPC worker demo unavailable on this host: ", ipc_start_error)
})
```

Managed startup occurs during registration. Rducks starts local mirai
workers, launches the NNG worker loop, pings each endpoint, then
broadcasts the closure, type metadata, NULL/error policy, packages, and
selected globals. If `ipc_endpoints` is supplied, those endpoints are
caller-owned worker processes; Rducks connects to them but does not stop
them.

## Inspect workers

[`rducks_ipc_workers()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_ipc_workers.md)
lists IPC providers known to the current R process. With `ping = TRUE`,
it also checks whether each endpoint responds.

``` r

if (isTRUE(ipc_available)) {
  rducks_ipc_workers(con)
  rducks_ipc_workers(con, ping = TRUE, timeout = min(ipc_timeout, 30))
} else {
  data.frame(status = "unavailable", reason = ipc_start_error)
}
#> <rducks_ipc_workers: 1 worker>
#>             runtime backend transport worker started task_state ping
#>  rducks-runtime-1-1   mirai       tcp    1/1    TRUE    running   ok
#>               endpoint
#>  tcp://127.0.0.1:36562
```

The result is an R-side provider view: runtime token, provider key,
backend, transport, endpoint, compute name, worker index, task state,
and optional ping status. It is not a DuckDB catalog listing.

## What `rducks_release()` does

`rducks_release(con)` detaches the connection-local Rducks state. It
also gives native code a safe main-thread point to release preserved R
objects that had to be queued by off-main destructors.

If this connection is the last Rducks attachment to the DuckDB runtime,
[`rducks_release()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_release.md)
additionally:

1.  asks the native extension to close local NNG client pools for that
    runtime
2.  keeps caller-supplied external endpoints alive
3.  sends stop requests to Rducks-managed local worker endpoints
4.  waits briefly for mirai tasks to resolve and collects resolved tasks
5.  tears down the local mirai compute with
    `mirai::daemons(0, .compute = ...)`
6.  unlinks local IPC socket paths
7.  removes the provider entry from the process-local store

It does **not** unregister DuckDB catalog functions and does not release
closures still owned by live native catalog metadata. Re-register the
same SQL name/signature to replace a scalar UDF implementation.

Weak-reference finalizers provide best-effort cleanup if a connection
object is garbage-collected, but deterministic code should call
`rducks_release(con)` before `DBI::dbDisconnect(con)`.
