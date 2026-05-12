# Stream a DuckDB query in data-frame batches

Opens a connection-bound query stream with explicit `next_batch()` and
[`close()`](https://rdrr.io/r/base/connections.html) methods. This is an
R-side streaming result/session API; it is not inferred from scalar UDF
IPC behavior and does not use the R-backed SQL table function path.

## Usage

``` r
rducks_query_stream(con, sql, batch_size = 1024L)
```

## Arguments

- con:

  A `duckdb_connection`.

- sql:

  SQL query string.

- batch_size:

  Default number of rows requested by `next_batch()`.

## Value

Object of class `rducks_query_stream` with `next_batch(n = NULL)`,
[`close()`](https://rdrr.io/r/base/connections.html), `is_closed()`,
`schema`, and `prototype` fields.

## Details

`next_batch()` returns the next data-frame batch or `NULL` at
end-of-stream. Returned batches carry the stream's inferred nanoarrow
schema as the `"rducks_nanoarrow_schema"` attribute.
[`close()`](https://rdrr.io/r/base/connections.html) clears the
underlying DBI result; it is safe to call more than once. A finalizer
also closes unclosed streams, and `rducks_release(con)` closes streams
registered on that connection before detaching connection-local state.
