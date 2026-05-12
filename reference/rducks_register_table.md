# Register an R table function in DuckDB

Registers a first-slice R-backed DuckDB table function. The registered
SQL table function accepts no SQL arguments and calls `fun()` once per
query on the recorded calling R thread. `fun()` must return a data frame
or named list of equal-length columns matching the declared `returns`
schema. Results are emitted to DuckDB in chunks and the query state
releases preserved R results on completion or error.

## Usage

``` r
rducks_register_table(con, name, fun, returns, chunk_size = 1024L)
```

## Arguments

- con:

  A `duckdb_connection`.

- name:

  SQL table function name.

- fun:

  Zero-argument R function returning a data frame or named list of
  columns.

- returns:

  Named list of output column type descriptors, such as
  `list(i = INTEGER, label = VARCHAR)`.

- chunk_size:

  Maximum number of rows emitted per DuckDB output chunk. Must be an
  integer from 1 to 1024.

## Value

Object of class `rducks_table_registration` containing the connection
and normalized table signature. The table function remains registered in
DuckDB even if this object is discarded.

## Details

This is intentionally separate from scalar/vectorized UDF registration:
table functions have their own bind/init/scan state and currently
support only the one-shot finite table shape. Use
`rducks_enable(con, threads = "single")` or otherwise set
`external_threads=1` plus `PRAGMA threads=1` before registration and
execution; worker-thread calls into R are rejected.
