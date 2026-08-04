# Getting Started with Rducks

`Rducks` is an R package plus a DuckDB extension for registering R
functions as DuckDB SQL functions. The extension owns the SQL catalog
objects; R supplies the closures and explicit type semantics.

The usual workflow is:

1.  create a DuckDB connection
2.  load and enable the Rducks extension
3.  register R-backed SQL functions
4.  query them through DuckDB
5.  call
    [`rducks_release()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_release.md)
    before disconnecting when deterministic cleanup matters

## Enable Rducks

``` r

library(DBI)
library(duckdb)
library(Rducks)

con <- dbConnect(duckdb(config = list(allow_unsigned_extensions = "true")))
#> duckdb keeps downloaded extensions and secrets in a temporary directory:
#> ℹ /tmp/RtmpLLvFb0/duckdb
#> This is removed when the R session ends.
#> • Extensions are re-downloaded each session.
#> • Secrets are lost.
#> ℹ Run duckdb(shared_home = TRUE) (or create ~/.duckdb) to keep them (suitable for most users).
#> ℹ Run duckdb(shared_home = FALSE) to accept the temporary directory (and silence this message).
#> ℹ See ?duckdb_storage for details and alternatives.
rducks_enable(con, threads = "single")
```

Rducks uses DuckDB’s unstable C extension ABI. The installed package
contains exact-version extension variants for DuckDB v1.5.0 through
v1.5.5, generated from the build manifest, and
[`rducks_enable()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_enable.md)
loads only the variant matching `SELECT version()` on `con`. There is no
fallback to another patch release; see [DuckDB Version
Compatibility](https://rgenomicsetl.github.io/Rducks/articles/duckdb-version-compatibility.md)
for details.

`threads = "single"` is the safest registration setting. You can select
a scalar-UDF execution plan (`transport = "inproc"` or
`transport = "ipc"`) before registration when you want worker-process
evaluation instead of the in-process default.

## Register a scalar UDF

When `args` is omitted, Rducks registers a dynamic DuckDB varargs UDF.
DuckDB binds concrete argument types at each SQL call site, and Rducks
materializes those values as if the effective signature had been
declared explicitly.

``` r

score_udf <- rducks_register_scalar_udf(
  con,
  name = "r_score",
  fun = function(row) {
    bonus <- if (identical(row$label, "high")) 100 else 0
    list(
      score = as.double(row$x + bonus),
      parts = as.double(c(row$x, bonus))
    )
  },
  returns = STRUCT(score = DOUBLE, parts = DOUBLE[]),
  side_effects = TRUE
)

DBI::dbGetQuery(con, "
  WITH input AS (
    SELECT struct_pack(x := x::DOUBLE, label := label) AS payload
    FROM (VALUES (2, 'low'), (21, 'high')) AS t(x, label)
  ), scored AS (
    SELECT r_score(payload) AS result FROM input
  )
  SELECT result.score AS score, result.parts AS parts
  FROM scored
")
#>   score   parts
#> 1     2    2, 0
#> 2   121 21, 100
```

Use `args = NULL` only for a true zero-argument UDF. Use an explicit
`args = ...` when you want to pin the SQL signature and fail binding of
other input types.

## Register an aggregate

Aggregates are separate from scalar-UDF execution plans. The current
aggregate API stores R object state and calls R
[`update()`](https://rdrr.io/r/stats/update.html),
[`combine()`](https://dplyr.tidyverse.org/reference/defunct.html), and
`finalize()` callbacks on the recorded R thread.

``` r

rducks_register_aggregate(
  con,
  name = "r_sum_i32",
  update = function(state, x) {
    if (is.null(state)) state <- 0L
    as.integer(state + x)
  },
  finalize = function(state) if (is.null(state)) NA_integer_ else state,
  args = INTEGER,
  returns = INTEGER
)
#> <rducks_aggregate_registration>
#>   registered: yes
#>   name:       r_sum_i32
#>   signature:  r_sum_i32(INTEGER) -> INTEGER

DBI::dbGetQuery(
  con,
  paste(
    "SELECT r_sum_i32(i) AS total",
    "FROM (VALUES (1::INTEGER), (2::INTEGER), (NULL::INTEGER)) t(i)"
  )
)
#>   total
#> 1     3
```

## Register a table function

[`rducks_register_table()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_register_table.md)
infers the SQL argument count from the R function formals and registers
those inputs as DuckDB `ANY`. The R function can return a finite data
frame/list or a
[`rducks_table_stream()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_table_stream.md)
for scan-time batches.

``` r

rducks_register_table(
  con,
  name = "r_rows",
  fun = function(n) data.frame(i = seq_len(as.integer(n))),
  chunk_size = 2L
)
#> <rducks_table_registration>
#>   registered: yes
#>   name:       r_rows
#>   signature:  r_rows(ANY) -> TABLE(<bind-time schema>)

DBI::dbGetQuery(con, "SELECT * FROM r_rows(3) ORDER BY i")
#>   i
#> 1 1
#> 2 2
#> 3 3
```

A streaming table function returns a prototype plus a `next_batch()`
callback:

``` r

rducks_register_table(
  con,
  name = "r_stream_rows",
  fun = function(n) {
    next_i <- 1L
    limit <- as.integer(n)
    rducks_table_stream(
      prototype = data.frame(i = integer()),
      next_batch = function(batch_size) {
        if (next_i > limit) return(NULL)
        hi <- min(limit, next_i + as.integer(batch_size) - 1L)
        out <- data.frame(i = seq.int(next_i, hi))
        next_i <<- hi + 1L
        out
      }
    )
  },
  chunk_size = 2L
)
#> <rducks_table_registration>
#>   registered: yes
#>   name:       r_stream_rows
#>   signature:  r_stream_rows(ANY) -> TABLE(<bind-time schema>)

DBI::dbGetQuery(con, "SELECT sum(i) AS total FROM r_stream_rows(5)")
#>   total
#> 1    15
```

## Stream query results back to R

[`rducks_query_stream()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_query_stream.md)
is for R callers that want native DuckDB result chunks instead of eager
[`DBI::dbGetQuery()`](https://dbi.r-dbi.org/reference/dbGetQuery.html)
materialization. Each `next_batch()` materializes one DuckDB chunk into
a data frame directly from DuckDB vectors.

``` r

stream <- rducks_query_stream(
  con,
  "SELECT i, i * i AS sq FROM range(10) tbl(i)"
)

repeat {
  batch <- stream$next_batch()
  if (is.null(batch)) break
  print(batch)
}
#>    i sq
#> 1  0  0
#> 2  1  1
#> 3  2  4
#> 4  3  9
#> 5  4 16
#> 6  5 25
#> 7  6 36
#> 8  7 49
#> 9  8 64
#> 10 9 81

stream$close()
```

## Release connection-local state

``` r

rducks_release(con)
DBI::dbDisconnect(con, shutdown = TRUE)
```

[`rducks_release()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_release.md)
detaches the connection-local Rducks view and, when this is the last
Rducks attachment to the DuckDB runtime, stops Rducks-managed local IPC
workers. It does not unregister DuckDB catalog functions.
