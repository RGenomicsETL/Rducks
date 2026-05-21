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
db <- duckdb::dbConnect(duckdb::duckdb())
rducks_enable(db)
#> Error in duckdb_result(connection = conn, stmt_lst = stmt_lst, arrow = arrow): Invalid Error: IO Error: Extension "/home/runner/work/_temp/Library/Rducks/rducks_extension/build/rducks.duckdb_extension" could not be loaded because its signature is either missing or invalid and unsigned extensions are disabled by configuration (allow_unsigned_extensions)
#> ℹ Context: rapi_execute
#> ℹ Error type: INVALID
rducks_runtime_stats(db)
#> Error in dbSendQuery(conn, statement, ...): Catalog Error: Scalar Function with name rducks_runtime_registry_entries does not exist!
#> Did you mean "__internal_decompress_string"?
#> 
#> LINE 1: SELECT rducks_runtime_registry_entries() AS registry_entries, rduc...
#>                ^
#> ℹ Context: rapi_prepare
#> ℹ Error type: CATALOG
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
