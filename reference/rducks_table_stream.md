# Create a streaming result for an Rducks table function

Return this object from a function registered with
[`rducks_register_table()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_table.md)
to expose a finite table without materializing all rows during DuckDB
bind. The `prototype` supplies the output column names and types. During
scan, Rducks repeatedly calls `next_batch(n)` and imports each returned
data frame, named list, `nanoarrow_array`, or one-batch
`nanoarrow_array_stream`. Return `NULL` from `next_batch()` to signal
end-of-stream.

## Usage

``` r
rducks_table_stream(
  prototype,
  next_batch,
  close = NULL,
  cardinality = NA_real_,
  exact = FALSE
)
```

## Arguments

- prototype:

  Data frame or named list whose column names and R types define the
  stream schema. A zero-row prototype is usually appropriate.

- next_batch:

  Function called as `next_batch(n)` or `next_batch()` if it has no
  formal arguments. It must return the next batch or `NULL` for EOF.

- close:

  Optional cleanup function.

- cardinality:

  Optional non-negative row count, or `NA` when unknown.

- exact:

  Whether `cardinality` is exact rather than an estimate.

## Value

Object of class `rducks_table_stream`.

## Details

`close`, when supplied, is called at most once when the stream reaches
EOF. Rducks also tries to close unreached EOF streams when DuckDB
releases the native bind state on the recorded R thread, and a finalizer
provides eventual best-effort cleanup if the stream object is later
garbage-collected. Use it to release file handles, sockets, iterators,
or other producer-side resources. `cardinality` is optional scan
metadata; set `exact = TRUE` only when the stream will emit exactly that
many rows.

## Examples

``` r
rows <- data.frame(x = 1:3)
i <- 0L
stream <- rducks_table_stream(
  prototype = rows[0, , drop = FALSE],
  next_batch = function(n) { i <<- i + 1L; if (i > 1L) NULL else rows }
)
stream
#> $prototype
#> [1] x
#> <0 rows> (or 0-length row.names)
#> 
#> $state
#> <environment: 0x55f742d98e98>
#> 
#> attr(,"class")
#> [1] "rducks_table_stream"
```
