# Describe Rducks execution mode semantics

`rducks_mode_semantics()` is the package-level schema for row and future
batch execution modes. It intentionally documents reserved modes as
reserved, so README/pkgdown text can describe the intended contract
without pretending that native batch registration is implemented.

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

## Details

`mode = "row"` is currently implemented. `mode = "nanoarrow_lapply"` is
the planned high-level batch convenience path: Rducks will use
nanoarrow-backed chunk arrays internally, materialize R vectors/lists
for the callback, and require a return value with exactly the input
chunk length. `mode = "arrow_nanoarrow"` is the planned lower-level
Arrow C Data Interface path where callbacks work with nanoarrow/Arrow
array objects directly.
