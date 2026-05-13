# Streaming query interface

`rducks_query_stream(con, sql, batch_size = 1024L)` is an R-side streaming
query API. It is a connection-bound result/session object, not a scalar-UDF IPC
feature and not an R-backed SQL table function.

## Public contract

- The returned `rducks_query_stream` object has `next_batch(n = NULL)`, `close()`,
  and `is_closed()` methods.
- `next_batch()` returns a data frame with up to `n` rows, or the stream default
  `batch_size` when `n` is `NULL`.
- End-of-stream is signaled by `NULL`, including empty results.
- `close()` clears the underlying DBI result and is idempotent.
- A finalizer closes unclosed streams as a best-effort safety net.
- `rducks_release(con)` closes streams registered on that connection before
  detaching connection-local state.

## Schema and batches

At stream creation, Rducks fetches a zero-row prototype from DuckDB and records
`nanoarrow::infer_nanoarrow_schema(prototype)`. The schema is available as
`stream$schema`; the zero-row data frame is available as `stream$prototype`.
Each non-empty batch returned by `next_batch()` carries the same schema as the
`"rducks_nanoarrow_schema"` attribute.

The current implementation returns data-frame batches because that is the stable
DBI/DuckDB R result shape. Future adapters can expose nanoarrow arrays or Arrow IPC bytes
without changing the stream lifetime rules.

## Ownership and errors

The stream owns one DBI result handle. Query resources remain live until
end-of-stream, `close()`, `rducks_release(con)`, or stream finalization. Streams
do not survive connection release for the current 0.1.0 API.

If query creation or batch fetch fails, the error is surfaced to the caller. A
fetch-time error closes the stream before rethrowing so the DBI result is not
left live after partial consumption.
