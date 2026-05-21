# Disable in-process queued scalar-UDF execution

Switches a Rducks-enabled DuckDB connection back to the direct serial
backend. Optionally updates DuckDB thread settings at the same time.

## Usage

``` r
rducks_disable_inproc(con, threads = NULL, external_threads = NULL)
```

## Arguments

- con:

  A `duckdb_connection`.

- threads:

  Optional positive integer to set with `PRAGMA threads`.

- external_threads:

  Optional positive integer to set with `SET external_threads`. Use
  `NULL` to leave unchanged.

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
rducks_enable_inproc(db)
#> Error in dbSendQuery(conn, statement, ...): Catalog Error: Scalar Function with name rducks_set_execution_backend does not exist!
#> Did you mean "struct_concat"?
#> 
#> LINE 1: SELECT rducks_set_execution_backend('posix-pthread-ptr:14023276681...
#>                ^
#> ℹ Context: rapi_prepare
#> ℹ Error type: CATALOG
rducks_disable_inproc(db)
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
