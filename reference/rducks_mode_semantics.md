# Describe Rducks execution mode semantics

`rducks_mode_semantics()` is the package-level schema for execution-mode
semantics. `mode = "row"` is currently the only public mode: Rducks
calls the R callback once for each DuckDB row. Future chunk or
Arrow-backed execution modes will be added only when they execute real
UDFs.

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
