# Reset Rducks scalar-UDF counters

Resets native per-scalar-UDF diagnostic counters without unregistering
any DuckDB catalog function. Current liveness gauges such as
pending/in-flight counts are preserved; their max fields are reset to
the current values.

## Usage

``` r
rducks_reset_udf_counters(con, name = NULL)
```

## Arguments

- con:

  A `duckdb_connection` with Rducks enabled.

- name:

  Optional SQL scalar-UDF function name registered with
  [`rducks_register_scalar_udf()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_register_scalar_udf.md).
  If `NULL`, reset counters for all native Rducks scalar UDFs in the
  database runtime.

## Value

Invisibly `TRUE` on success.

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
rducks_enable(db, threads = "single")
rducks_register_scalar_udf(db, "my_fn", function(x) x + 1L,
  args = list(INTEGER), returns = INTEGER)
#> <rducks_scalar_udf_registration>
#>   registered:      yes
#>   name:            my_fn
#>   evaluation_mode: scalar
#>   plan:            direct+serial
#>   signature:       my_fn(INTEGER) -> INTEGER
rducks_reset_udf_counters(db, "my_fn")
rducks_release(db)
DBI::dbDisconnect(db)
# }
```
