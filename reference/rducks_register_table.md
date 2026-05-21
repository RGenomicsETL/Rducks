# Register an R table function in DuckDB

Registers an R-backed DuckDB table function. The registered SQL table
function infers its positional SQL argument count from `formals(fun)`
and registers those arguments with DuckDB's dynamic `ANY` type. During
DuckDB's bind phase, Rducks converts the actual SQL argument values to R
scalars/lists and calls `fun(...)` on the recorded calling R thread.
`fun()` may return either a finite data frame/named list or a
[`rducks_table_stream()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_table_stream.md)
object.

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

  R function returning a data frame, named list of columns, or
  [`rducks_table_stream()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_table_stream.md).
  Its finite formal argument count defines the SQL positional argument
  count; each positional argument is registered as DuckDB `ANY` and
  converted at bind time from the actual SQL value.

- chunk_size:

  Maximum number of rows emitted per DuckDB output chunk. Must be an
  integer from 1 to 1024.

## Value

Object of class `rducks_table_registration` containing the connection
and normalized table signature. The table function remains registered in
DuckDB even if this object is discarded.

## Details

For finite results, Rducks imports the full result into one DuckDB data
chunk during bind and then emits row batches during scan. For streaming
results, bind uses only the stream prototype to define the DuckDB
schema; scan calls `next_batch()` repeatedly and imports one returned
batch at a time. Both paths honor DuckDB projection pushdown, so
unreferenced columns are not copied from imported chunks into DuckDB
output chunks.

This is intentionally separate from DuckDB scalar-UDF registration
through
[`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md):
table functions have their own bind/init/scan state, bind-time dynamic
schemas, and positional SQL arguments fixed by the R function's finite
formal argument count. Variadic `...` arguments are not supported. If
you already have a static R data frame to expose as a virtual table,
prefer
[`duckdb::duckdb_register()`](https://r.duckdb.org/reference/duckdb_register.html);
DuckDB's R package routes that through its native data-frame scan path.
Use `rducks_enable(con, threads = "single")` or otherwise set
`external_threads=1` plus `PRAGMA threads=1` before registration and
execution; worker-thread calls into R are rejected.

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb())
rducks_enable(db)
#> Error in duckdb_result(connection = conn, stmt_lst = stmt_lst, arrow = arrow): Invalid Error: IO Error: Extension "/home/runner/work/_temp/Library/Rducks/rducks_extension/build/rducks.duckdb_extension" could not be loaded because its signature is either missing or invalid and unsigned extensions are disabled by configuration (allow_unsigned_extensions)
#> ℹ Context: rapi_execute
#> ℹ Error type: INVALID
rducks_register_table(db, "my_table", function() data.frame(x = 1:3))
#> Error: Rducks R-backed functions require DuckDB to execute R code on the calling R thread; call rducks_enable(con, threads = 'single') or set external_threads=1 and PRAGMA threads=1 before registering R-backed functions
DBI::dbGetQuery(db, "SELECT * FROM my_table()")
#> Error in dbSendQuery(conn, statement, ...): Catalog Error: Table Function with name my_table does not exist!
#> Did you mean "query_table"?
#> 
#> LINE 1: SELECT * FROM my_table()
#>                       ^
#> ℹ Context: rapi_prepare
#> ℹ Error type: CATALOG
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
