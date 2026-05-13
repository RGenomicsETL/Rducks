# Streaming query interface

`rducks_query_stream(con, sql, batch_size = 1024L)` is an R-side streaming
query API. It is a connection-bound result/session object, not a scalar-UDF IPC
feature and not an R-backed SQL table function.

## Implementation contract

The query is opened by the Rducks DuckDB extension using the extension-owned
DuckDB connection recorded at extension initialization. Rducks prepares the SQL
with `duckdb_prepare()`, opens a streaming result with
`duckdb_execute_prepared_streaming()`, and fetches result chunks with
`duckdb_stream_fetch_chunk()`.

Each fetched DuckDB data chunk is exported through DuckDB Arrow C Data with
`duckdb_data_chunk_to_arrow()`. The R wrapper materializes the Arrow C Data
using the package's existing nanoarrow/Rducks conversion helpers, including the
same decimal, enum, list, array, struct, map, UUID, huge integer, interval, BLOB,
and BIT handling used by scalar-UDF marshalling. The heavy `arrow` package is
not required.

Because execution uses the extension-owned DuckDB connection, database-scoped
objects are visible, but temporary tables or views that exist only on the
caller's DBI connection are not part of the stream query scope.

## Public contract

- The returned `rducks_query_stream` object has `next_batch(n = NULL)`, `close()`,
  and `is_closed()` methods.
- `next_batch()` returns a data frame with up to `n` rows, or the stream default
  `batch_size` when `n` is `NULL`.
- DuckDB may fetch a larger native chunk internally; Rducks buffers any remainder
  for later `next_batch()` calls.
- End-of-stream is signaled by `NULL`, including empty results.
- `close()` clears the native DuckDB streaming result and is idempotent.
- A finalizer closes unclosed streams as a best-effort safety net.
- `rducks_release(con)` closes streams registered on that connection before
  detaching connection-local state.

## Schema and batches

At stream creation, Rducks materializes a zero-row prototype from the native
DuckDB result schema. The schema is available as `stream$schema`; the zero-row
data frame is available as `stream$prototype`. Each non-empty batch returned by
`next_batch()` carries the same schema as the `"rducks_nanoarrow_schema"`
attribute.

The current R-facing batch representation is a data frame. That is a wrapper
choice over the DuckDB-chunk-to-Arrow-C-Data translation layer, not a fallback to
DBI result pagination and not an Arrow IPC transport.

## Ownership and errors

The stream owns one native DuckDB streaming result in the Rducks extension.
Query resources remain live until end-of-stream, `close()`, `rducks_release(con)`,
or stream finalization. Streams do not survive connection release for the
current 0.1.0 API.

If query creation or batch fetch fails, the error is surfaced to the caller. A
fetch-time error closes the stream before rethrowing so the native result is not
left live after partial consumption.
