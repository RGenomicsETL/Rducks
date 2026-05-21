# Enable in-process queued scalar-UDF execution

Switches a Rducks-enabled DuckDB connection to an `inproc_concurrent`
execution plan for subsequent scalar-UDF registrations and updates the
native runtime backend. This backend preserves R's thread discipline:
DuckDB worker-side scalar-UDF callbacks submit chunk requests to an
extension-owned queue, and the recorded main R thread drains the queue
and performs all R API work. This is a same-process scheduling mode, not
a performance promise; R function calls are still serialized on the main
R thread.

## Usage

``` r
rducks_enable_inproc(con, threads = NULL, external_threads = NULL)
```

## Arguments

- con:

  A `duckdb_connection` already enabled with
  [`rducks_enable()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable.md).

- threads:

  Optional positive integer to set with `PRAGMA threads` before enabling
  the in-process backend. Use `NULL` to leave unchanged.

- external_threads:

  Optional positive integer to set with `SET external_threads` before
  enabling the in-process backend. Use `NULL` to leave unchanged. For
  actual DuckDB worker concurrency, keep this smaller than `threads`
  (for example `threads = 4, external_threads = 1`).

## Value

`con`, invisibly.

## Details

This is a compatibility helper for the `arrow_r`/`arrow_c` in-process
queue. New code can call
[`rducks_set_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_set_execution_plan.md)
directly with `rducks_execution_plan("arrow_r", "inproc_concurrent")` or
`rducks_execution_plan("arrow_c", "inproc_concurrent")`. Select the plan
before registering scalar UDFs whose reported execution plan should be
the queued in-process path.

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb())
rducks_enable(db)
#> Error in duckdb_result(connection = conn, stmt_lst = stmt_lst, arrow = arrow): Invalid Error: IO Error: Extension "/home/runner/work/_temp/Library/Rducks/rducks_extension/build/rducks.duckdb_extension" could not be loaded because its signature is either missing or invalid and unsigned extensions are disabled by configuration (allow_unsigned_extensions)
#> ℹ Context: rapi_execute
#> ℹ Error type: INVALID
rducks_enable_inproc(db)
#> Error in dbSendQuery(conn, statement, ...): Catalog Error: Scalar Function with name rducks_set_execution_backend does not exist!
#> Did you mean "struct_concat"?
#> 
#> LINE 1: SELECT rducks_set_execution_backend('posix-pthread-ptr:14023276681...
#>                ^
#> ℹ Context: rapi_prepare
#> ℹ Error type: CATALOG
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
