# Set the Rducks execution plan for a connection

Stores the R-side default execution plan used by subsequent
[`rducks_register_scalar_udf()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_register_scalar_udf.md)
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
  [`rducks_enable()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_enable.md).

- plan:

  An
  [`rducks_execution_plan()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_execution_plan.md)
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
db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
#> duckdb keeps downloaded extensions and secrets in a temporary directory:
#> ℹ /tmp/RtmpY861Yl/duckdb
#> This is removed when the R session ends.
#> • Extensions are re-downloaded each session.
#> • Secrets are lost.
#> ℹ Run duckdb(shared_home = TRUE) (or create ~/.duckdb) to keep them (suitable for most users).
#> ℹ Run duckdb(shared_home = FALSE) to accept the temporary directory (and silence this message).
#> ℹ See ?duckdb_storage for details and alternatives.
rducks_enable(db)
rducks_set_execution_plan(db, rducks_execution_plan("inproc"))
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
