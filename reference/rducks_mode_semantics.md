# Describe Rducks scalar-UDF evaluation mode semantics

`rducks_mode_semantics()` is the package-level schema for Rducks
evaluation modes used by DuckDB scalar UDFs registered with
[`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md).
This is distinct from DuckDB function kind (scalar, aggregate, or table)
and from Rducks execution plans. `mode = "scalar"` calls the R function
once for each DuckDB row. `mode = "vectorized"` calls the R function
once per DuckDB chunk with one R vector/list-column per declared
argument. Vectorized mode is exposed for `arrow_r`, direct `arrow_c`,
and worker-provider `arrow_ipc` plans.

## Usage

``` r
rducks_mode_semantics(mode = NULL)
```

## Arguments

- mode:

  Optional character vector of scalar-UDF evaluation mode names. When
  `NULL`, all known modes are returned.

## Value

A data frame describing status, call granularity, input and return
shape, NULL handling, length checks, error behavior, threading, and copy
semantics for each scalar-UDF evaluation mode.
