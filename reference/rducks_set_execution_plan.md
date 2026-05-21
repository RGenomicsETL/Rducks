# Set the Rducks execution plan for a connection

Stores the R-side default execution plan used by subsequent
[`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md)
calls through this connection and updates the native runtime backend
needed by that plan. Scalar-UDF registration still defines Rducks
evaluation semantics such as scalar row calls versus vectorized chunk
calls, declared types, NULL handling, error handling, and side effects.
The selected evaluator/marshalling for an already-registered scalar UDF
remains frozen in its database-catalog metadata.

## Usage

``` r
rducks_set_execution_plan(
  con,
  plan = rducks_execution_plan(),
  threads = NULL,
  external_threads = NULL
)
```

## Arguments

- con:

  A `duckdb_connection` already enabled with
  [`rducks_enable()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable.md).

- plan:

  An
  [`rducks_execution_plan()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_execution_plan.md)
  object.

- threads:

  Optional positive integer to set with `PRAGMA threads`.

- external_threads:

  Optional positive integer to set with `SET external_threads`. Use
  `NULL` to restore/keep the previous setting after Rducks briefly
  forces single-thread SQL execution to update its native backend on the
  recorded main R thread. For actual DuckDB worker concurrency, keep
  this smaller than `threads`.

## Value

`con`, invisibly.

## Examples

``` r
# \donttest{
db <- duckdb::dbConnect(duckdb::duckdb())
rducks_enable(db)
#> Error in duckdb_result(connection = conn, stmt_lst = stmt_lst, arrow = arrow): Invalid Error: IO Error: Extension "/home/runner/work/_temp/Library/Rducks/rducks_extension/build/rducks.duckdb_extension" could not be loaded because its signature is either missing or invalid and unsigned extensions are disabled by configuration (allow_unsigned_extensions)
#> ℹ Context: rapi_execute
#> ℹ Error type: INVALID
rducks_set_execution_plan(db, rducks_execution_plan("arrow_c", "serial"))
#> Error in dbSendQuery(conn, statement, ...): Catalog Error: Scalar Function with name rducks_set_execution_backend does not exist!
#> Did you mean "struct_concat"?
#> 
#> LINE 1: SELECT rducks_set_execution_backend('posix-pthread-ptr:14023276681...
#>                ^
#> ℹ Context: rapi_prepare
#> ℹ Error type: CATALOG
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
