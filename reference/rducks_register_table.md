# Register an R table function in DuckDB

Registers an R function as a DuckDB table function. The R function is
called on the recorded R thread to produce either a finite result (a
data frame or named list of equal-length columns) or a
[`rducks_table_stream()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_table_stream.md)
producer for scan-time batches. Column types are inferred from the
returned columns, and the extension fills DuckDB output vectors directly
from the R columns, with no wire serialization for the in-process scan.

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
  [`rducks_table_stream()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_table_stream.md).
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

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb(config = rducks_duckdb_config(list(threads = "2"))))
#> duckdb keeps downloaded extensions and secrets in a temporary directory:
#> ℹ /tmp/RtmpC1M7PW/duckdb
#> This is removed when the R session ends.
#> • Extensions are re-downloaded each session.
#> • Secrets are lost.
#> ℹ Run duckdb(shared_home = TRUE) (or create ~/.duckdb) to keep them (suitable for most users).
#> ℹ Run duckdb(shared_home = FALSE) to accept the temporary directory (and silence this message).
#> ℹ See ?duckdb_storage for details and alternatives.
rducks_enable(db, threads = "single")
rducks_register_table(db, "my_numbers", function(n) {
  data.frame(i = seq_len(n), square = seq_len(n)^2)
})
#> <rducks_table_registration>
#>   registered: yes
#>   name:       my_numbers
#>   signature:  my_numbers(ANY) -> TABLE(<bind-time schema>)
DBI::dbGetQuery(db, "SELECT * FROM my_numbers(3)")
#>   i square
#> 1 1      1
#> 2 2      4
#> 3 3      9
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
