# Stream a DuckDB query in batches

Opens a connection-bound query stream with explicit `next_batch()` and
[`close()`](https://rdrr.io/r/base/connections.html) methods. The query
itself is executed by the Rducks DuckDB extension using DuckDB's native
streaming result and data-chunk APIs; each fetched DuckDB chunk is
exported through DuckDB Arrow C Data. Rducks can either return the owned
nanoarrow record-batch object directly or materialize it with the
package's Rducks/nanoarrow helpers. This is an R-side result/session
API; it is not inferred from scalar UDF IPC behavior and does not use
the R-backed SQL table function path. Because execution uses the
extension-owned DuckDB connection, database-scoped objects are visible
but temporary tables/views that exist only on the caller's DBI
connection are not part of the stream query scope. Delivery into R runs
on the recorded R thread: even record-batch mode creates R
external-pointer objects and installs nanoarrow finalizers, so Rducks
does not call R/nanoarrow code from arbitrary DuckDB worker threads.

## Usage

``` r
rducks_query_stream(
  con,
  sql,
  batch_size = 1024L,
  format = c("data.frame", "record_batch", "nanoarrow")
)
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

- format:

  Default batch representation. `"data.frame"` materializes batches to
  base R data frames. `"record_batch"` returns the owned
  `nanoarrow_array` record batch directly. `"nanoarrow"` is accepted as
  an alias for `"record_batch"`.

## Value

Object of class `rducks_query_stream` with
`next_batch(n = NULL, format = NULL)`,
[`close()`](https://rdrr.io/r/base/connections.html), `is_closed()`,
`schema`, and `prototype` fields.

## Details

`next_batch()` returns the next batch or `NULL` at end-of-stream. With
`format = "data.frame"` it returns a base R data-frame batch. With
`format = "record_batch"` it returns a `nanoarrow_array` struct array
with an attached `nanoarrow_schema`; nanoarrow's R finalizer owns the
Arrow C Data release callbacks, so callers can materialize later without
Rducks copying the batch to R vectors first. Returned batches carry the
stream's DuckDB/nanoarrow schema as the `"rducks_nanoarrow_schema"`
attribute. [`close()`](https://rdrr.io/r/base/connections.html) clears
the native streaming result; it is safe to call more than once. A
finalizer also closes unclosed streams, and `rducks_release(con)` closes
streams registered on that connection before detaching connection-local
state.
