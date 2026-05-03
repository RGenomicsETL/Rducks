# Describe Rducks execution mode semantics

`rducks_mode_semantics()` is the package-level schema for execution-mode
semantics. `mode = "scalar"` calls the R function once for each DuckDB
row. `mode = "vectorized"` calls the R function once per DuckDB chunk
with one R vector/list-column per declared argument. Both modes are
implemented on top of DuckDB Arrow C Data export/import plus nanoarrow.

## Usage

``` r
rducks_mode_semantics(mode = NULL)
```

## Arguments

- mode:

  Optional character vector of mode names. When `NULL`, all known modes
  are returned.

## Value

A data frame describing status, call granularity, input and return
shape, NULL handling, length checks, error behavior, threading, and copy
semantics for each mode.
