# Inspect native runtime registry counters

Returns process-local diagnostics for database-scoped native runtime
entries and their extension-owned DuckDB connections. The `con` argument
is only the enabled DuckDB connection used to reach the diagnostic SQL
functions; the counters are process-global, not scoped only to `con`.
`active_entries` means entries whose stored database handle has not been
marked as a stale registry alias, and `stale_entries` means entries
retained only to avoid reusing an old raw database address. DuckDB's C
extension API does not currently provide a clean database-close callback
for this package, so these counters are accounting diagnostics rather
than deterministic lifetime guarantees. `connections_current` and
`native_release_supported` are derived R-side summary fields. For
file-backed databases, Rducks closes extension-owned DuckDB connections
when the last Rducks attachment to a runtime is released; the
process-local runtime entry itself is retained as inert metadata so
catalog destructors and stale database-address detection remain safe.

## Usage

``` r
rducks_runtime_stats(con)
```

## Arguments

- con:

  An enabled `duckdb_connection`.

## Value

A one-row data frame with runtime registry and connection counters.

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
rducks_enable(db)
rducks_runtime_stats(db)
#>   registry_entries active_entries stale_entries entries_created stale_aliases
#> 1               18             18             0              18             0
#>   connections_opened connections_closed connections_current
#> 1                 36                  0                  36
#>   connection_open_failed queue_init_failed native_release_supported
#> 1                      0                 0                     TRUE
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
