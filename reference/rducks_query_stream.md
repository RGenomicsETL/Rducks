# Stream a DuckDB query in data-frame batches

Opens a connection-bound query stream with explicit `next_batch()` and
[`close()`](https://rdrr.io/r/base/connections.html) methods. The query
itself is executed by the Rducks DuckDB extension using DuckDB's native
streaming result and data-chunk APIs; Rducks converts each fetched
DuckDB chunk through DuckDB Arrow C Data and the package's nanoarrow
materializers. This is an R-side result/session API; it is not inferred
from scalar UDF IPC behavior and does not use the R-backed SQL table
function path. Because execution uses the extension-owned DuckDB
connection, database-scoped objects are visible but temporary
tables/views that exist only on the caller's DBI connection are not part
of the stream query scope.

## Usage

``` r
rducks_query_stream(con, sql, batch_size = 1024L)
```

## Arguments

- con:

  A `duckdb_connection` with Rducks enabled.

- sql:

  SQL query string.

- batch_size:

  Maximum number of rows returned by `next_batch()` when its `n`
  argument is `NULL`. DuckDB may fetch a larger native chunk internally;
  Rducks buffers any remainder for later `next_batch()` calls.

## Value

Object of class `rducks_query_stream` with `next_batch(n = NULL)`,
[`close()`](https://rdrr.io/r/base/connections.html), `is_closed()`,
`schema`, and `prototype` fields.

## Details

`next_batch()` returns the next data-frame batch or `NULL` at
end-of-stream. Returned batches carry the stream's DuckDB/nanoarrow
schema as the `"rducks_nanoarrow_schema"` attribute.
[`close()`](https://rdrr.io/r/base/connections.html) clears the native
streaming result; it is safe to call more than once. A finalizer also
closes unclosed streams, and `rducks_release(con)` closes streams
registered on that connection before detaching connection-local state.
