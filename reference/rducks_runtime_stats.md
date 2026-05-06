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
than deterministic lifetime guarantees.

## Usage

``` r
rducks_runtime_stats(con)
```

## Arguments

- con:

  An enabled `duckdb_connection`.

## Value

A one-row data frame with runtime registry and connection counters.
