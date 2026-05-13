# Register an R table function in DuckDB

Registers an R-backed DuckDB table function. The registered SQL table
function infers its positional SQL argument count from `formals(fun)`
and registers those arguments with DuckDB's dynamic `ANY` type. During
DuckDB's bind phase, Rducks converts the actual SQL argument values to R
scalars/lists, calls `fun(...)` on the recorded calling R thread, and
infers the DuckDB output schema from the returned data frame or named
list of equal-length columns. It then converts the result through a
nanoarrow Arrow C Data stream, imports it into a DuckDB chunk, and emits
row batches from that imported chunk during table-function scans. Scans
honor DuckDB projection pushdown, so unreferenced columns are not copied
from the imported chunk into the output chunk.

## Usage

``` r
rducks_register_table(con, name, fun, chunk_size = 1024L)
```

## Arguments

- con:

  A `duckdb_connection`.

- name:

  SQL table function name.

- fun:

  R function returning a data frame or named list of columns. Its finite
  formal argument count defines the SQL positional argument count; each
  positional argument is registered as DuckDB `ANY` and converted at
  bind time from the actual SQL value.

- chunk_size:

  Maximum number of rows emitted per DuckDB output chunk. Must be an
  integer from 1 to 1024.

## Value

Object of class `rducks_table_registration` containing the connection
and normalized table signature. The table function remains registered in
DuckDB even if this object is discarded.

## Details

This is intentionally separate from DuckDB scalar-UDF registration
through
[`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md):
table functions have their own bind/init/scan state and currently
support only the one-shot finite table shape. DuckDB table functions can
have bind-time dynamic schemas and broad input signatures; this Rducks
API follows that model for output schemas and positional input types,
while the number of SQL arguments is fixed by the R function's formal
argument count. Variadic `...` arguments are not supported. If you
already have a static R data frame to expose as a virtual table, prefer
[`duckdb::duckdb_register()`](https://r.duckdb.org/reference/duckdb_register.html);
DuckDB's R package routes that through its native data-frame scan path.
Use `rducks_enable(con, threads = "single")` or otherwise set
`external_threads=1` plus `PRAGMA threads=1` before registration and
execution; worker-thread calls into R are rejected.
