# Describe Rducks NULL, NA, NaN, and Inf semantics

`rducks_value_semantics()` is the package-level schema for DuckDB
scalar-UDF missing and non-finite value handling. It is intended to be
rendered directly in README and pkgdown documentation, and to keep the
documented NULL/NA/NaN/Inf contract close to the type descriptors used
by the marshaller.

## Usage

``` r
rducks_value_semantics(x = NULL)
```

## Arguments

- x:

  Optional scalar type tokens or constructed `rducks_type` descriptors.
  When `NULL`, all currently implemented DuckDB scalar-UDF scalar type
  semantics are returned. Constructed descriptors such as
  `DECIMAL(10, 2)`, `ENUM(c("a", "b"))`,
  `UNION(i = INTEGER, s = VARCHAR)`, `INTEGER[]`, `INTEGER[3]`,
  `STRUCT(a = INTEGER)`, and `MAP(VARCHAR, INTEGER)` can be requested
  explicitly.

## Value

A data frame with one row per requested type descriptor and columns
describing SQL NULL input handling, R missing/non-finite return
handling, Rducks value-class binary operation behavior, and error
semantics.

## Details

With `null_handling = "default"`, top-level SQL `NULL` inputs
short-circuit to SQL `NULL` and the R function is not called. The
`special_null_argument` column describes what the R function receives
with `null_handling = "special"`.

Return semantics are stated from R back to DuckDB. For DuckDB scalar
UDFs, top-level `NULL` returns map to SQL `NULL`; type-specific R `NA`
values also map to SQL `NULL` where a missing representation exists.
`NaN` and `Inf` are values only for `FLOAT` and `DOUBLE`; integer, date,
time, timestamp, and exact Rducks value classes reject non-finite
values.

## Examples

``` r
rducks_value_semantics()
#>    duckdb_type descriptor_kind   r_value_class
#> 1      BOOLEAN          scalar         logical
#> 2      TINYINT          scalar         integer
#> 3     UTINYINT          scalar         integer
#> 4     SMALLINT          scalar         integer
#> 5    USMALLINT          scalar         integer
#> 6      INTEGER          scalar         integer
#> 7     UINTEGER          scalar         numeric
#> 8       BIGINT          scalar   rducks_bigint
#> 9      UBIGINT          scalar  rducks_ubigint
#> 10       FLOAT          scalar         numeric
#> 11      DOUBLE          scalar         numeric
#> 12     VARCHAR          scalar       character
#> 13        BLOB          scalar             raw
#> 14    GEOMETRY          scalar             raw
#> 15     VARIANT          scalar  rducks_variant
#> 16        DATE          scalar            Date
#> 17        TIME          scalar         numeric
#> 18   TIMESTAMP          scalar         POSIXct
#> 19     HUGEINT          scalar  rducks_hugeint
#> 20    UHUGEINT          scalar rducks_uhugeint
#> 21        UUID          scalar     rducks_uuid
#> 22    INTERVAL          scalar rducks_interval
#> 23         BIT          scalar     rducks_bits
#>                                            default_null_input
#> 1  short-circuit to SQL NULL result; R function is not called
#> 2  short-circuit to SQL NULL result; R function is not called
#> 3  short-circuit to SQL NULL result; R function is not called
#> 4  short-circuit to SQL NULL result; R function is not called
#> 5  short-circuit to SQL NULL result; R function is not called
#> 6  short-circuit to SQL NULL result; R function is not called
#> 7  short-circuit to SQL NULL result; R function is not called
#> 8  short-circuit to SQL NULL result; R function is not called
#> 9  short-circuit to SQL NULL result; R function is not called
#> 10 short-circuit to SQL NULL result; R function is not called
#> 11 short-circuit to SQL NULL result; R function is not called
#> 12 short-circuit to SQL NULL result; R function is not called
#> 13 short-circuit to SQL NULL result; R function is not called
#> 14 short-circuit to SQL NULL result; R function is not called
#> 15 short-circuit to SQL NULL result; R function is not called
#> 16 short-circuit to SQL NULL result; R function is not called
#> 17 short-circuit to SQL NULL result; R function is not called
#> 18 short-circuit to SQL NULL result; R function is not called
#> 19 short-circuit to SQL NULL result; R function is not called
#> 20 short-circuit to SQL NULL result; R function is not called
#> 21 short-circuit to SQL NULL result; R function is not called
#> 22 short-circuit to SQL NULL result; R function is not called
#> 23 short-circuit to SQL NULL result; R function is not called
#>    special_null_argument                               sql_nan_inf_input
#> 1                     NA          not representable for this DuckDB type
#> 2            NA_integer_          not representable for this DuckDB type
#> 3            NA_integer_          not representable for this DuckDB type
#> 4            NA_integer_          not representable for this DuckDB type
#> 5            NA_integer_          not representable for this DuckDB type
#> 6            NA_integer_          not representable for this DuckDB type
#> 7               NA_real_          not representable for this DuckDB type
#> 8                   NULL          not representable for this DuckDB type
#> 9                   NULL          not representable for this DuckDB type
#> 10              NA_real_ DuckDB NaN/Inf pass through as R numeric values
#> 11              NA_real_ DuckDB NaN/Inf pass through as R numeric values
#> 12         NA_character_          not representable for this DuckDB type
#> 13                  NULL          not representable for this DuckDB type
#> 14                  NULL          not representable for this DuckDB type
#> 15                  NULL          not representable for this DuckDB type
#> 16               Date NA          not representable for this DuckDB type
#> 17              NA_real_          not representable for this DuckDB type
#> 18            POSIXct NA          not representable for this DuckDB type
#> 19                  NULL          not representable for this DuckDB type
#> 20                  NULL          not representable for this DuckDB type
#> 21                  NULL          not representable for this DuckDB type
#> 22                  NULL          not representable for this DuckDB type
#> 23                  NULL          not representable for this DuckDB type
#>    r_null_return
#> 1       SQL NULL
#> 2       SQL NULL
#> 3       SQL NULL
#> 4       SQL NULL
#> 5       SQL NULL
#> 6       SQL NULL
#> 7       SQL NULL
#> 8       SQL NULL
#> 9       SQL NULL
#> 10      SQL NULL
#> 11      SQL NULL
#> 12      SQL NULL
#> 13      SQL NULL
#> 14      SQL NULL
#> 15      SQL NULL
#> 16      SQL NULL
#> 17      SQL NULL
#> 18      SQL NULL
#> 19      SQL NULL
#> 20      SQL NULL
#> 21      SQL NULL
#> 22      SQL NULL
#> 23      SQL NULL
#>                                                                             r_na_return
#> 1                                                               NA_logical_ -> SQL NULL
#> 2                                                               NA_integer_ -> SQL NULL
#> 3                                                               NA_integer_ -> SQL NULL
#> 4                                                               NA_integer_ -> SQL NULL
#> 5                                                               NA_integer_ -> SQL NULL
#> 6                                                               NA_integer_ -> SQL NULL
#> 7                                                                  NA_real_ -> SQL NULL
#> 8                                                         rducks_bigint(NA) -> SQL NULL
#> 9                                                        rducks_ubigint(NA) -> SQL NULL
#> 10                                                                 NA_real_ -> SQL NULL
#> 11                                                                 NA_real_ -> SQL NULL
#> 12                                                            NA_character_ -> SQL NULL
#> 13                              raw vectors have no NA payload; use R NULL for SQL NULL
#> 14                          raw WKB vectors have no NA payload; use R NULL for SQL NULL
#> 15 use R NULL for SQL NULL; nested missingness is encoded in the VARIANT storage object
#> 16                                                       Date NA / NA_real_ -> SQL NULL
#> 17                                                                 NA_real_ -> SQL NULL
#> 18                                                    POSIXct NA / NA_real_ -> SQL NULL
#> 19                                                       rducks_hugeint(NA) -> SQL NULL
#> 20                                                      rducks_uhugeint(NA) -> SQL NULL
#> 21                                                          rducks_uuid(NA) -> SQL NULL
#> 22                                    any NA component in rducks_interval() -> SQL NULL
#> 23                                           no NA bit payload; use R NULL for SQL NULL
#>               r_nan_return               r_inf_return
#> 1           not applicable             not applicable
#> 2                    error                      error
#> 3                    error                      error
#> 4                    error                      error
#> 5                    error                      error
#> 6                    error                      error
#> 7                    error                      error
#> 8                    error                      error
#> 9                    error                      error
#> 10 preserved as DuckDB NaN preserved as DuckDB +/-Inf
#> 11 preserved as DuckDB NaN preserved as DuckDB +/-Inf
#> 12          not applicable             not applicable
#> 13          not applicable             not applicable
#> 14          not applicable             not applicable
#> 15          not applicable             not applicable
#> 16                   error                      error
#> 17                   error                      error
#> 18                   error                      error
#> 19                   error                      error
#> 20                   error                      error
#> 21                   error                      error
#> 22                   error                      error
#> 23                   error                      error
#>                                                                                         binary_ops
#> 1                                                                    no Rducks-specific binary ops
#> 2                                                                    no Rducks-specific binary ops
#> 3                                                                    no Rducks-specific binary ops
#> 4                                                                    no Rducks-specific binary ops
#> 5                                                                    no Rducks-specific binary ops
#> 6                                                                    no Rducks-specific binary ops
#> 7                                                                    no Rducks-specific binary ops
#> 8                       rducks_bigint +, -, comparisons; NA propagates; range errors remain errors
#> 9   rducks_ubigint +, -, comparisons; NA propagates; unsigned underflow/range errors remain errors
#> 10                                                  ordinary R numeric semantics in the R function
#> 11                                                  ordinary R numeric semantics in the R function
#> 12                                                                   no Rducks-specific binary ops
#> 13                                                                   no Rducks-specific binary ops
#> 14                                                                   no Rducks-specific binary ops
#> 15       no Rducks-specific VARIANT binary ops; use DuckDB SQL functions such as variant_extract()
#> 16                                                                   no Rducks-specific binary ops
#> 17                                                                   no Rducks-specific binary ops
#> 18                                                                   no Rducks-specific binary ops
#> 19                     rducks_hugeint +, -, comparisons; NA propagates; range errors remain errors
#> 20 rducks_uhugeint +, -, comparisons; NA propagates; unsigned underflow/range errors remain errors
#> 21                                                                   no Rducks-specific binary ops
#> 22           rducks_interval + and -; NA components propagate; component overflow remains an error
#> 23                                    rducks_bits &, |, !, rducks_bits_xor(); NA bits are rejected
#>                                                                      error_semantics
#> 1                                   non-logical values are incompatible with BOOLEAN
#> 2                         NaN, Inf, fractional, and out-of-range return values error
#> 3                         NaN, Inf, fractional, and out-of-range return values error
#> 4                         NaN, Inf, fractional, and out-of-range return values error
#> 5                         NaN, Inf, fractional, and out-of-range return values error
#> 6                         NaN, Inf, fractional, and out-of-range return values error
#> 7                         NaN, Inf, fractional, and out-of-range return values error
#> 8                non-integer strings, numeric NaN/Inf, and out-of-range values error
#> 9                non-integer strings, numeric NaN/Inf, and out-of-range values error
#> 10                                    NA is NULL; NaN and Inf are valid FLOAT values
#> 11                                   NA is NULL; NaN and Inf are valid DOUBLE values
#> 12 values that cannot be converted to character error during checking or marshalling
#> 13                                                       non-raw return values error
#> 14                                                   non-raw WKB return values error
#> 15            malformed VARIANT storage objects error during checking or marshalling
#> 16                            NaN, Inf, fractional days, and out-of-range days error
#> 17        NaN, Inf, values outside [0, 86400), and values rounding to 24:00:00 error
#> 18                                NaN, Inf, and out-of-range timestamp seconds error
#> 19               non-integer strings, numeric NaN/Inf, and out-of-range values error
#> 20               non-integer strings, numeric NaN/Inf, and out-of-range values error
#> 21                               NA UUID values are NULL; malformed UUID text errors
#> 22             NaN/Inf components and months/days/micros outside DuckDB ranges error
#> 23                     BIT inputs must contain only 0/1 or TRUE/FALSE; NA bits error
#>                                                              notes
#> 1                                                                 
#> 2                                                                 
#> 3                                                                 
#> 4                                                                 
#> 5                                                                 
#> 6                                                                 
#> 7          uses R numeric because UINTEGER exceeds R integer range
#> 8                                exact signed 64-bit integer value
#> 9                              exact unsigned 64-bit integer value
#> 10                            DuckDB FLOAT is widened to R numeric
#> 11                                                                
#> 12                                            string copied into R
#> 13                                             bytes copied into R
#> 14                GEOMETRY crosses the R boundary as WKB raw bytes
#> 15 VARIANT crosses the R boundary as DuckDB's typed storage object
#> 16                                           days since 1970-01-01
#> 17                               microseconds converted to seconds
#> 18                               microseconds converted to seconds
#> 19                                        exact Rducks value class
#> 20                                        exact Rducks value class
#> 21                                        exact Rducks value class
#> 22                                        exact Rducks value class
#> 23                                        exact Rducks value class
rducks_value_semantics(INTEGER)
#>   duckdb_type descriptor_kind r_value_class
#> 1     INTEGER          scalar       integer
#>                                           default_null_input
#> 1 short-circuit to SQL NULL result; R function is not called
#>   special_null_argument                      sql_nan_inf_input r_null_return
#> 1           NA_integer_ not representable for this DuckDB type      SQL NULL
#>               r_na_return r_nan_return r_inf_return
#> 1 NA_integer_ -> SQL NULL        error        error
#>                      binary_ops
#> 1 no Rducks-specific binary ops
#>                                              error_semantics notes
#> 1 NaN, Inf, fractional, and out-of-range return values error      
rducks_value_semantics(DECIMAL(10L, 2L))
#>      duckdb_type descriptor_kind  r_value_class
#> 1 DECIMAL(10, 2)         decimal rducks_decimal
#>                                           default_null_input
#> 1 short-circuit to SQL NULL result; R function is not called
#>   special_null_argument                    sql_nan_inf_input
#> 1                  NULL not representable for DuckDB DECIMAL
#>                                                    r_null_return
#> 1 SQL NULL for the top-level value; nested NULLs map recursively
#>                                    r_na_return r_nan_return r_inf_return
#> 1 rducks_decimal(NA, width, scale) -> SQL NULL        error        error
#>                                                                      binary_ops
#> 1 rducks_decimal +, -, comparisons; NA propagates; matching scales are required
#>                                                                       error_semantics
#> 1 NaN/Inf numeric inputs, scale/width mismatch, and DECIMAL arithmetic overflow error
#>                           notes
#> 1 exact fixed-point value class
```
