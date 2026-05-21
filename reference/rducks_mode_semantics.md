# Describe Rducks scalar-UDF evaluation mode semantics

`rducks_mode_semantics()` is the package-level schema for Rducks
evaluation modes used by DuckDB scalar UDFs registered with
[`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md).
This is distinct from DuckDB function kind (scalar, aggregate, or table)
and from Rducks execution plans. `mode = "scalar"` calls the R function
once for each DuckDB row. `mode = "vectorized"` calls the R function
once per DuckDB chunk with one R vector/list-column per declared or
dynamically bound argument. Vectorized mode is exposed for `arrow_r`,
direct `arrow_c`, and worker-provider `arrow_ipc` plans.

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
#>         mode      status            call_granularity
#> 1     scalar implemented          one R call per row
#> 2 vectorized implemented one R call per DuckDB chunk
#>                                                               input_shape
#> 1 one scalar/composite R value per declared or dynamically bound argument
#> 2     one R vector/list-column per declared or dynamically bound argument
#>                                                            return_shape
#> 1 one scalar/composite R value compatible with the declared return type
#> 2  one R vector/list of values compatible with the declared return type
#>                                                                                                                                                   null_semantics
#> 1                                                                      default NULL-in/NULL-out short-circuits; special mode passes scalar-shaped NA/NULL values
#> 2 default mode evaluates only rows with no top-level SQL NULL inputs and scatters SQL NULLs back; special mode passes all rows with scalar-shaped NA/NULL values
#>                                                     length_semantics
#> 1                               one output value per R function call
#> 2 return length must equal the number of evaluated rows in the chunk
#>                                                                                                                                    error_semantics
#> 1                  R function errors become SQL NULL with exception_handling = 'return_null'; type-checking and marshalling errors abort the query
#> 2 R function errors make all evaluated rows SQL NULL with exception_handling = 'return_null'; type-checking and marshalling errors abort the query
#>                                                                                                                                                                       threading
#> 1   R API work for arrow_r/arrow_c runs on the recorded main R thread; arrow_ipc + multiprocess_parallel evaluates scalar rows inside provider workers after Arrow IPC encoding
#> 2 arrow_r and arrow_c vectorized work runs on the recorded main R thread; arrow_ipc + multiprocess_parallel offloads vectorized chunk work through the selected worker provider
#>                                                                                                                                                                                                                                    copy_semantics
#> 1                                                                       DuckDB chunks are exported/imported through Arrow C Data for in-process plans; arrow_ipc plans copy chunk/task payloads into Arrow IPC raw bytes before process transport
#> 2 arrow_r vectorized chunks are exported/imported through Arrow C Data; arrow_c vectorized materializes supported DuckDB vectors directly in native C; arrow_ipc plans copy chunk/task payloads into Arrow IPC raw bytes before process transport
#>                                                                                                                                                          notes
#> 1 scalar arrow_ipc loops over rows inside the worker; in-process queuing is available for deadlock-safe same-process scheduling, not for parallel R evaluation
#> 2            batch/chunk call-shape used by arrow_r, direct arrow_c, and Arrow IPC worker-provider backends; zero-argument vectorized UDFs are not exposed yet
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
#>                                                                                                                                                                     threading
#> 1 R API work for arrow_r/arrow_c runs on the recorded main R thread; arrow_ipc + multiprocess_parallel evaluates scalar rows inside provider workers after Arrow IPC encoding
#>                                                                                                                                                              copy_semantics
#> 1 DuckDB chunks are exported/imported through Arrow C Data for in-process plans; arrow_ipc plans copy chunk/task payloads into Arrow IPC raw bytes before process transport
#>                                                                                                                                                          notes
#> 1 scalar arrow_ipc loops over rows inside the worker; in-process queuing is available for deadlock-safe same-process scheduling, not for parallel R evaluation
rducks_mode_semantics("vectorized")
#>         mode      status            call_granularity
#> 1 vectorized implemented one R call per DuckDB chunk
#>                                                           input_shape
#> 1 one R vector/list-column per declared or dynamically bound argument
#>                                                           return_shape
#> 1 one R vector/list of values compatible with the declared return type
#>                                                                                                                                                   null_semantics
#> 1 default mode evaluates only rows with no top-level SQL NULL inputs and scatters SQL NULLs back; special mode passes all rows with scalar-shaped NA/NULL values
#>                                                     length_semantics
#> 1 return length must equal the number of evaluated rows in the chunk
#>                                                                                                                                    error_semantics
#> 1 R function errors make all evaluated rows SQL NULL with exception_handling = 'return_null'; type-checking and marshalling errors abort the query
#>                                                                                                                                                                       threading
#> 1 arrow_r and arrow_c vectorized work runs on the recorded main R thread; arrow_ipc + multiprocess_parallel offloads vectorized chunk work through the selected worker provider
#>                                                                                                                                                                                                                                    copy_semantics
#> 1 arrow_r vectorized chunks are exported/imported through Arrow C Data; arrow_c vectorized materializes supported DuckDB vectors directly in native C; arrow_ipc plans copy chunk/task payloads into Arrow IPC raw bytes before process transport
#>                                                                                                                                               notes
#> 1 batch/chunk call-shape used by arrow_r, direct arrow_c, and Arrow IPC worker-provider backends; zero-argument vectorized UDFs are not exposed yet
```
