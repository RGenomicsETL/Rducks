# Describe Rducks scalar-UDF evaluation mode semantics

`rducks_mode_semantics()` is the package-level schema for Rducks
evaluation modes used by DuckDB scalar UDFs registered with
[`rducks_register_scalar_udf()`](https://rgenomicsetl.github.io/Rducks/reference/rducks_register_scalar_udf.md).
This is distinct from DuckDB function kind (scalar, aggregate, or table)
and from Rducks execution plans. `mode = "scalar"` calls the R function
once for each DuckDB row. `mode = "vectorized"` calls the R function
once per DuckDB chunk by default, with one R vector/list-column per
declared or dynamically bound argument. An in-process registration can
explicitly permit merging queued chunks with `coalesce = TRUE` when its
results are invariant to that change in call boundaries. See the
registration function for the supported signatures and error policy.
Vectorized mode is available with both the direct and IPC backends for
their supported signatures.

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

## Examples

``` r
rducks_mode_semantics()
#>         mode      status
#> 1     scalar implemented
#> 2 vectorized implemented
#>                                                                        call_granularity
#> 1                                                                    one R call per row
#> 2 one R call per DuckDB chunk by default; coalesce = TRUE permits merging queued chunks
#>                                                               input_shape
#> 1 one scalar/composite R value per declared or dynamically bound argument
#> 2     one R vector/list-column per declared or dynamically bound argument
#>                                                            return_shape
#> 1 one scalar/composite R value compatible with the declared return type
#> 2  one R vector/list of values compatible with the declared return type
#>                                                                                                                                                   null_semantics
#> 1                                                                      default NULL-in/NULL-out short-circuits; special mode passes scalar-shaped NA/NULL values
#> 2 default mode evaluates only rows with no top-level SQL NULL inputs and scatters SQL NULLs back; special mode passes all rows with scalar-shaped NA/NULL values
#>                                                                                          length_semantics
#> 1                                                                    one output value per R function call
#> 2 return length must equal the number of evaluated rows in the R call; NULL returns SQL NULL for all rows
#>                                                                                                                                                                                         error_semantics
#> 1                                                                       R function errors become SQL NULL with exception_handling = 'return_null'; type-checking and marshalling errors abort the query
#> 2 R function errors make all evaluated rows in the original chunk SQL NULL with exception_handling = 'return_null'; coalescing requires 'rethrow'; type-checking and marshalling errors abort the query
#>                                                                                                             threading
#> 1 direct in-process R API work runs on the recorded main R thread; queued in-process calls are drained by that thread
#> 2       direct vectorized work runs on the recorded main R thread; queued in-process calls are drained by that thread
#>                                                       copy_semantics
#> 1               DuckDB vectors are materialized directly to R values
#> 2 DuckDB vectors are materialized directly to R vectors/list-columns
#>                                                                                                                                                                                                                 notes
#> 1 the ipc (wire) transport covers fixed-width scalars, VARCHAR/BLOB, DECIMAL, INTERVAL, ENUM, BIT, GEOMETRY, MAP, UNION, VARIANT, and LIST/ARRAY/STRUCT of supported types; VARIANT is runtime-probed and fail-closed
#> 2                          coalesce = TRUE requires a static direct signature with plain scalar inputs, no side effects, and results invariant to combining chunks; zero-argument vectorized UDFs are not exposed yet
rducks_mode_semantics("scalar")
#>     mode      status   call_granularity
#> 1 scalar implemented one R call per row
#>                                                               input_shape
#> 1 one scalar/composite R value per declared or dynamically bound argument
#>                                                            return_shape
#> 1 one scalar/composite R value compatible with the declared return type
#>                                                                              null_semantics
#> 1 default NULL-in/NULL-out short-circuits; special mode passes scalar-shaped NA/NULL values
#>                       length_semantics
#> 1 one output value per R function call
#>                                                                                                                   error_semantics
#> 1 R function errors become SQL NULL with exception_handling = 'return_null'; type-checking and marshalling errors abort the query
#>                                                                                                             threading
#> 1 direct in-process R API work runs on the recorded main R thread; queued in-process calls are drained by that thread
#>                                         copy_semantics
#> 1 DuckDB vectors are materialized directly to R values
#>                                                                                                                                                                                                                 notes
#> 1 the ipc (wire) transport covers fixed-width scalars, VARCHAR/BLOB, DECIMAL, INTERVAL, ENUM, BIT, GEOMETRY, MAP, UNION, VARIANT, and LIST/ARRAY/STRUCT of supported types; VARIANT is runtime-probed and fail-closed
rducks_mode_semantics("vectorized")
#>         mode      status
#> 1 vectorized implemented
#>                                                                        call_granularity
#> 1 one R call per DuckDB chunk by default; coalesce = TRUE permits merging queued chunks
#>                                                           input_shape
#> 1 one R vector/list-column per declared or dynamically bound argument
#>                                                           return_shape
#> 1 one R vector/list of values compatible with the declared return type
#>                                                                                                                                                   null_semantics
#> 1 default mode evaluates only rows with no top-level SQL NULL inputs and scatters SQL NULLs back; special mode passes all rows with scalar-shaped NA/NULL values
#>                                                                                          length_semantics
#> 1 return length must equal the number of evaluated rows in the R call; NULL returns SQL NULL for all rows
#>                                                                                                                                                                                         error_semantics
#> 1 R function errors make all evaluated rows in the original chunk SQL NULL with exception_handling = 'return_null'; coalescing requires 'rethrow'; type-checking and marshalling errors abort the query
#>                                                                                                       threading
#> 1 direct vectorized work runs on the recorded main R thread; queued in-process calls are drained by that thread
#>                                                       copy_semantics
#> 1 DuckDB vectors are materialized directly to R vectors/list-columns
#>                                                                                                                                                                                        notes
#> 1 coalesce = TRUE requires a static direct signature with plain scalar inputs, no side effects, and results invariant to combining chunks; zero-argument vectorized UDFs are not exposed yet
```
