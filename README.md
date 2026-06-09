
# Rducks

Rducks is an R package plus DuckDB extension for registering R functions
as DuckDB scalar UDFs.

This branch removes the Arrow/nanoarrow data plane. The package now
builds without `nanoarrow`, without vendored nanoarrow/flatcc sources,
and without the old Arrow IPC/query-stream/duckplyr execution surfaces.
The remaining supported execution path is direct in-process marshalling
from DuckDB vectors to R values on the recorded R thread.

## Quick example

``` r
db <- duckdb::dbConnect(duckdb::duckdb(config = list(allow_unsigned_extensions = "true")))
rducks_enable(db, threads = "single")
rducks_register_scalar_udf(
  db, "plus_one", function(x) x + 1L,
  args = list(INTEGER), returns = INTEGER
)
DBI::dbGetQuery(db, "SELECT plus_one(41::INTEGER) AS x")
rducks_release(db)
DBI::dbDisconnect(db, shutdown = TRUE)
```

The experimental Quack codec lives in `src/quack_core.c` and the R glue
in `src/quack_codec.c`; it is covered by tinytests as the replacement
wire-format foundation, but IPC worker execution is intentionally not
advertised until the native DuckDB-vector adapter is implemented.
