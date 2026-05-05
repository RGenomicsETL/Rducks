# Execute SQL through the Rducks streaming scheduler

Runs `sql` through the C API `rducks_query_stream()` table-function
surface. This path is intended for Rducks-owned scheduling: the native
extension prepares the inner query on its captured DuckDB connection,
drives DuckDB's streaming pending-result API, drains queued Rducks work
between pending tasks, and returns fetched result chunks to R.

## Usage

``` r
rducks_query_stream(con, sql)
```

## Arguments

- con:

  A `duckdb_connection` with Rducks enabled.

- sql:

  SQL query string to execute.

## Value

A data frame result.
