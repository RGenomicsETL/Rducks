# List Rducks-managed IPC workers

Lists the local Rducks NNG providers currently known to this R process.
These are the managed workers used by `transport = "ipc"` scalar-UDF
execution plans when `ipc_endpoints` is not supplied. Caller-supplied
external endpoints are shown as external providers.

## Usage

``` r
rducks_ipc_workers(con = NULL, ping = FALSE, timeout = 1)
```

## Arguments

- con:

  Optional DuckDB connection. When supplied, only providers attached to
  that connection's Rducks runtime token are listed. With `NULL`, all
  providers known to this R process are listed.

- ping:

  Logical scalar. If `TRUE`, send a lightweight NNG ping to every listed
  endpoint and report `ok` or the ping error.

- timeout:

  Positive timeout in seconds used for `ping = TRUE`.

## Value

A data frame with one row per configured worker endpoint.

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
rducks_enable(db)
rducks_ipc_workers(db)
#> <rducks_ipc_workers> no workers
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
