# Detach Rducks connection-local state

Detaches Rducks' connection-local R state for `con`. This clears the
current default execution plan and releases this connection's R-side
runtime anchor. It does not drop DuckDB catalog functions, unregister
UDFs, or release native-owned R closures that are still referenced by
database-scoped catalog metadata. If sibling DBI connections are
attached to the same DuckDB database runtime, their database-scoped
Rducks registration metadata remains visible.

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

Call
[`rducks_enable()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable.md)
again before using `con` for further Rducks registrations or
connection-local plan changes.
