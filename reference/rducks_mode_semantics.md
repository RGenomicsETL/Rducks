# Describe Rducks execution mode semantics

`rducks_mode_semantics()` is the package-level schema for execution-mode
semantics. `mode = "row"` is currently the only public mode: Rducks
calls the R callback once for each DuckDB row. Row mode is already
implemented on top of DuckDB Arrow C Data export/import plus nanoarrow.
Future batch/chunk modes will be added only when they actually invoke
callbacks once per batch/chunk.

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
