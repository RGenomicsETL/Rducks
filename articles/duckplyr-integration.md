# duckplyr Integration

Rducks can make selected ordinary R calls inside a duckplyr pipeline
available as DuckDB scalar UDF calls. The goal is not to emulate dplyr
fallback in R; the goal is to keep the pipeline in DuckDB while DuckDB
calls registered Rducks functions for the operations you explicitly opt
into.

## Setup

Use a DuckDB connection with unsigned extension loading enabled and
enable Rducks on that connection. `threads = "single"` is the
recommended registration setting for R-backed functions.

``` r

suppressPackageStartupMessages({
  library(DBI)
  library(dplyr)
  library(duckdb)
  library(duckplyr)
  library(Rducks)
})

con <- DBI::dbConnect(
  duckdb::duckdb(config = list(allow_unsigned_extensions = "true")),
  dbdir = ":memory:"
)
rducks_enable(con, threads = "single")

input <- data.frame(
  id = 1:6,
  x = as.numeric(c(2, 5, 8, 13, 21, 34)),
  label = c("low", "low", "mid", "mid", "high", "high")
)
DBI::dbWriteTable(con, "duckplyr_scores", input)

scores <- duckplyr::read_sql_duckdb(
  "SELECT * FROM duckplyr_scores",
  con = con,
  prudence = "stingy"
)
```

## Why a bridge is needed

A plain R helper in a duckplyr expression is not automatically a DuckDB
SQL function. With stingy fallback and fallback collection disabled,
duckplyr should fail instead of silently pulling data back to R.

``` r

local_score <- function(x, label) {
  bonus <- if (identical(label, "high")) 100 else if (identical(label, "mid")) 10 else 0
  as.double(x + bonus)
}

blocked <- tryCatch({
  scores |>
    mutate(score = local_score(x, label)) |>
    collect()
  FALSE
}, error = function(e) {
  message("fallback blocked: ", conditionMessage(e))
  TRUE
})
#> fallback blocked: This operation cannot be carried out by DuckDB, and the input is a
#> stingy duckplyr frame.
#> ℹ Use `compute(prudence = "lavish")` to materialize to temporary storage and
#>   continue with duckplyr.
#> ℹ See `vignette("prudence")` for other options.
#> Caused by error in `mutate()`:
#> ! Can't translate function `local_score()`.
stopifnot(isTRUE(blocked))
```

## Register selected R helpers for duckplyr

[`rducks_with_duckplyr()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_with_duckplyr.md)
captures the duckplyr expression, registers the named R helpers as
dynamic-argument Rducks scalar UDFs, rewrites matching calls to
DuckDB-function calls, and evaluates the rewritten expression. DuckDB
still needs an explicit return type for every registered helper.

``` r

out <- rducks_with_duckplyr(
  con,
  scores |>
    mutate(score = local_score(x, label)) |>
    filter(score >= 100) |>
    select(id, label, score) |>
    arrange(id) |>
    collect(),
  returns = list(local_score = DOUBLE)
)
out
#> # A tibble: 2 × 3
#>      id label score
#> * <int> <chr> <dbl>
#> 1     5 high    121
#> 2     6 high    134
```

The
[`with.duckdb_connection()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_with_duckplyr.md)
method is equivalent when `rducks_returns` is supplied:

``` r

out_with <- with(
  con,
  scores |>
    mutate(score = local_score(x, label)) |>
    filter(score >= 100) |>
    select(id, label, score) |>
    arrange(id) |>
    collect(),
  rducks_returns = list(local_score = DOUBLE)
)
identical(out_with, out)
#> [1] TRUE
```

## Why scalar mode is the default

A duckplyr call such as `local_score(x, label)` is translated as a SQL
scalar function call in a relational expression. That SQL surface is
row-oriented: DuckDB sees one logical value for each argument and needs
one logical result. Rducks therefore defaults the bridge to
`mode = "scalar"`, which lets ordinary R helpers be written as row
functions.

Rducks scalar-UDF *evaluation mode* is still an implementation choice
behind that SQL scalar function. If a helper is vectorized over whole
chunks and returns a vector of the same length, the duckplyr bridge can
register it with `mode = "vectorized"`:

``` r

local_score_vec <- function(x, label) {
  as.double(x + ifelse(label == "high", 100, ifelse(label == "mid", 10, 0)))
}

out_vec <- rducks_with_duckplyr(
  con,
  scores |>
    mutate(score = local_score_vec(x, label)) |>
    filter(score >= 100) |>
    select(id, label, score) |>
    arrange(id) |>
    collect(),
  returns = list(local_score_vec = DOUBLE),
  mode = "vectorized"
)
identical(out_vec, out)
#> [1] TRUE
```

The [`with()`](https://rdrr.io/r/base/with.html) method exposes the same
choice as `rducks_mode`.

## Execution plans: arrow_r, arrow_c, and IPC

Do not confuse `mode = "scalar"` / `"vectorized"` with the Rducks
execution plan. The mode controls whether the R closure is called per
row or per DuckDB chunk. The execution plan controls marshalling and
concurrency (`arrow_r`, `arrow_c`, or `arrow_ipc`). The duckplyr bridge
uses the current connection plan at the time it registers helpers.

For example, this executed chunk switches to the direct
`arrow_c + serial` plan before registering and evaluating a duckplyr
helper:

``` r

rducks_set_execution_plan(
  con,
  rducks_execution_plan("arrow_c", "serial"),
  threads = 1L,
  external_threads = 1L
)

local_plus_c <- function(x) as.double(x + 1)

rducks_with_duckplyr(
  con,
  scores |>
    mutate(y = local_plus_c(x)) |>
    select(id, y) |>
    arrange(id) |>
    collect(),
  returns = list(local_plus_c = DOUBLE),
  mode = "vectorized"
)
#> # A tibble: 6 × 2
#>      id     y
#> * <int> <dbl>
#> 1     1     3
#> 2     2     6
#> 3     3     9
#> 4     4    14
#> 5     5    22
#> 6     6    35
```

IPC is the same axis: select an `arrow_ipc + multiprocess_parallel`
execution plan before registering the helper. The current high-level
duckplyr bridge registers helpers and evaluates the expression in one
call, so it is best for simple IPC runs or for plans whose registration
and execution thread settings are the same. If you need the full pattern
of registering under single-thread DuckDB settings and then widening
`threads` / `external_threads` for a parallel IPC query, register the
UDF explicitly with
[`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md)
and call it from duckplyr via duckplyr’s `dd$function_name(...)` SQL
escape hatch, or wrap that two-phase pattern in your own helper.

## Cleanup

``` r

rducks_release(con)
DBI::dbDisconnect(con, shutdown = TRUE)
restore_duckplyr_env()
```
