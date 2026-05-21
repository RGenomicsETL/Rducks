# Detach Rducks connection-local state

Detaches Rducks' connection-local R state for `con`. This clears the
current default execution plan and releases this connection's R-side
runtime anchor. It does not drop DuckDB catalog functions, unregister
scalar UDFs, or release native-owned R closures that are still
referenced by database-scoped catalog metadata. If sibling DBI
connections are attached to the same DuckDB database runtime, their
database-scoped Rducks registration metadata remains visible. For
`arrow_ipc + multiprocess_parallel`, releasing the last Rducks
attachment to a runtime also closes native client pools for
Rducks-launched local workers and stops those local mirai/NNG workers.
If `ipc_endpoints` was supplied, those URLs name user-owned worker
processes; Rducks does not send stop requests to them during release.
For file-backed databases, releasing the last attachment also closes
Rducks' extension-owned DuckDB connections, which lets the DuckDB file
be closed and reopened in the same R process on platforms with strict
file locking.

## Usage

``` r
rducks_release(con)

rducks_detach(con)
```

## Arguments

- con:

  A `duckdb_connection`.

## Value

`con`, invisibly.

## Details

Rducks deliberately keeps the plain `duckdb_connection` object and does
not override DBI's
[`dbDisconnect()`](https://dbi.r-dbi.org/reference/dbDisconnect.html)
method. Call `rducks_release(con)` explicitly before
`DBI::dbDisconnect(con)` when you want deterministic connection-local
Rducks cleanup; weak-reference finalizers provide only best-effort
cleanup if the connection object is garbage-collected.

Call
[`rducks_enable()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable.md)
again before using `con` for further Rducks registrations or
connection-local plan changes.
