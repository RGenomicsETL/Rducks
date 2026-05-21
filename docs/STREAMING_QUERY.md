# Streaming query interface

`rducks_query_stream(con, sql, batch_size = 1024L)` is an R-side streaming
query API. It is a connection-bound result/session object, not a scalar-UDF IPC
feature and not an R-backed SQL table function.

## Implementation contract

The query is opened by the Rducks DuckDB extension using a dedicated
extension-owned query-stream DuckDB connection created at extension
initialization. This stream connection is separate from the extension-owned
connection used for dynamic scalar/table/aggregate registration. Rducks prepares
the SQL with `duckdb_prepare()`, opens a streaming pending result with
`duckdb_pending_prepared_streaming()`, materializes the streaming result with
`duckdb_execute_pending()`, verifies it with `duckdb_result_is_streaming()`, and
fetches result chunks with `duckdb_stream_fetch_chunk()`.

Each fetched DuckDB data chunk is exported through DuckDB Arrow C Data with
`duckdb_data_chunk_to_arrow()`. The R wrapper can either return the owned
nanoarrow record batch directly or materialize the Arrow C Data using the
package's existing nanoarrow/Rducks conversion helpers, including the same
decimal, enum, list, array, struct, map, UUID, huge integer, interval, BLOB,
GEOMETRY, BIT, and VARIANT-storage handling used by scalar-UDF marshalling. The
heavy `arrow` package is not required.

Because execution uses the dedicated extension-owned query-stream connection,
database-scoped objects are visible, but temporary tables or views that exist
only on the caller's DBI connection are not part of the stream query scope. A
caller connection currently supports one active native query stream at a time.
Delivery into R runs on the recorded R thread: even record-batch mode creates R
external-pointer objects and installs nanoarrow finalizers, so Rducks does not
call R/nanoarrow code from arbitrary DuckDB worker threads.

## Public contract

- The returned `rducks_query_stream` object has
  `next_batch(n = NULL, format = NULL)`, `close()`, and `is_closed()` methods.
- `next_batch()` returns up to `n` rows, or the stream default `batch_size` when
  `n` is `NULL`.
- With `format = "data.frame"` it materializes a base R data frame.
- With `format = "record_batch"` it returns a `nanoarrow_array` struct array
  with an attached schema. `format = "nanoarrow"` is accepted as an alias.
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

The native batch representation is DuckDB Arrow C Data wrapped by nanoarrow
external pointers. Nanoarrow finalizers own the Arrow C Data release callbacks,
so record-batch mode can hand the batch to the caller without copying it into R
vectors first. Data-frame mode is a materialization choice over that layer, not a
fallback to DBI result pagination and not an Arrow IPC transport. Rducks does not
promise that DuckDB's C API export itself is zero-copy; it promises that Rducks
will not add a data-frame materialization copy when `format = "record_batch"` is
used.

## Ownership and errors

The stream owns one native DuckDB streaming result in the Rducks extension.
Query resources remain live until end-of-stream, `close()`, `rducks_release(con)`,
or stream finalization. Streams do not survive connection release for the
current API.

If query creation or batch fetch fails, the error is surfaced to the caller. A
fetch-time error closes the stream before rethrowing so the native result is not
left live after partial consumption.
