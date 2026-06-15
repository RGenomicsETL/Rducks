# Describe how Rducks argument values are passed to R functions

`rducks_argument_type_mapping()` is the package-level source of truth
for the R value shape used when DuckDB argument values are marshalled
into an R function call. It is used by scalar-UDF registration checks
and the direct native marshalling adapter.

## Usage

``` r
rducks_argument_type_mapping(x = NULL)
```

## Arguments

- x:

  Optional scalar type tokens or constructed `rducks_type` descriptors.
  When `NULL`, all currently implemented DuckDB scalar-UDF scalar
  argument mappings are returned. Composite mappings should be requested
  with constructors such as `INTEGER[]`, `INTEGER[3]`,
  `STRUCT(a = INTEGER)`, and `MAP(VARCHAR, INTEGER)`.

## Value

A data frame with one row per requested type descriptor.

## Details

With `null_handling = "default"`, top-level SQL `NULL` inputs
short-circuit to a SQL `NULL` result and the R function is not called.
The `special_null_argument` column describes the value passed only when
`null_handling = "special"`. This value is type-specific: ordinary R
scalar types receive typed `NA` values, while exact Rducks value
classes, binary values, and top-level composite values receive R `NULL`.
Within homogeneous scalar lists/arrays, SQL `NULL` elements are
represented as typed `NA` values where the child type has an R `NA`
representation; nested composite `NULL` values are represented as R
`NULL`.

The default table contains all scalar descriptors supported by the
direct scalar-UDF marshalling adapter. `DECIMAL`, `ENUM`, `UNION`, and
composite descriptors can be requested explicitly to inspect their
recursive R function shapes.

## Examples

``` r
rducks_argument_type_mapping()
#>    duckdb_type descriptor_kind   r_value_class              r_argument_shape
#> 1      BOOLEAN          scalar         logical                logical scalar
#> 2      TINYINT          scalar         integer                integer scalar
#> 3     UTINYINT          scalar         integer                integer scalar
#> 4     SMALLINT          scalar         integer                integer scalar
#> 5    USMALLINT          scalar         integer                integer scalar
#> 6      INTEGER          scalar         integer                integer scalar
#> 7     UINTEGER          scalar         numeric                numeric scalar
#> 8       BIGINT          scalar   rducks_bigint          rducks_bigint scalar
#> 9      UBIGINT          scalar  rducks_ubigint         rducks_ubigint scalar
#> 10       FLOAT          scalar         numeric                numeric scalar
#> 11      DOUBLE          scalar         numeric                numeric scalar
#> 12     VARCHAR          scalar       character              character scalar
#> 13        BLOB          scalar             raw                    raw vector
#> 14    GEOMETRY          scalar             raw       raw WKB geometry vector
#> 15     VARIANT          scalar  rducks_variant rducks_variant storage object
#> 16        DATE          scalar            Date                   Date scalar
#> 17        TIME          scalar         numeric        numeric seconds scalar
#> 18   TIMESTAMP          scalar         POSIXct                POSIXct scalar
#> 19     HUGEINT          scalar  rducks_hugeint         rducks_hugeint scalar
#> 20    UHUGEINT          scalar rducks_uhugeint        rducks_uhugeint scalar
#> 21        UUID          scalar     rducks_uuid            rducks_uuid scalar
#> 22    INTERVAL          scalar rducks_interval        rducks_interval scalar
#> 23         BIT          scalar     rducks_bits            rducks_bits scalar
#>    special_null_argument                                    copy_semantics
#> 1                     NA                                      boxed scalar
#> 2            NA_integer_                                      boxed scalar
#> 3            NA_integer_                                      boxed scalar
#> 4            NA_integer_                                      boxed scalar
#> 5            NA_integer_                                      boxed scalar
#> 6            NA_integer_                                      boxed scalar
#> 7               NA_real_                                      boxed scalar
#> 8                   NULL                          boxed exact Rducks value
#> 9                   NULL                          boxed exact Rducks value
#> 10              NA_real_                                      boxed scalar
#> 11              NA_real_                                      boxed scalar
#> 12         NA_character_                              string copied into R
#> 13                  NULL                               bytes copied into R
#> 14                  NULL                           WKB bytes copied into R
#> 15                  NULL recursive R allocation for DuckDB VARIANT storage
#> 16               Date NA                                      boxed scalar
#> 17              NA_real_                                      boxed scalar
#> 18            POSIXct NA                                      boxed scalar
#> 19                  NULL                          boxed exact Rducks value
#> 20                  NULL                          boxed exact Rducks value
#> 21                  NULL                          boxed exact Rducks value
#> 22                  NULL                          boxed exact Rducks value
#> 23                  NULL                          boxed exact Rducks value
#>    integer_uses_r_double float32_widens_to_r_double precision_may_be_lost
#> 1                  FALSE                      FALSE                 FALSE
#> 2                  FALSE                      FALSE                 FALSE
#> 3                  FALSE                      FALSE                 FALSE
#> 4                  FALSE                      FALSE                 FALSE
#> 5                  FALSE                      FALSE                 FALSE
#> 6                  FALSE                      FALSE                 FALSE
#> 7                   TRUE                      FALSE                 FALSE
#> 8                  FALSE                      FALSE                 FALSE
#> 9                  FALSE                      FALSE                 FALSE
#> 10                 FALSE                       TRUE                 FALSE
#> 11                 FALSE                      FALSE                 FALSE
#> 12                 FALSE                      FALSE                 FALSE
#> 13                 FALSE                      FALSE                 FALSE
#> 14                 FALSE                      FALSE                 FALSE
#> 15                 FALSE                      FALSE                 FALSE
#> 16                 FALSE                      FALSE                 FALSE
#> 17                 FALSE                      FALSE                 FALSE
#> 18                 FALSE                      FALSE                 FALSE
#> 19                 FALSE                      FALSE                 FALSE
#> 20                 FALSE                      FALSE                 FALSE
#> 21                 FALSE                      FALSE                 FALSE
#> 22                 FALSE                      FALSE                 FALSE
#> 23                 FALSE                      FALSE                 FALSE
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
rducks_argument_type_mapping(INTEGER)
#>   duckdb_type descriptor_kind r_value_class r_argument_shape
#> 1     INTEGER          scalar       integer   integer scalar
#>   special_null_argument copy_semantics integer_uses_r_double
#> 1           NA_integer_   boxed scalar                 FALSE
#>   float32_widens_to_r_double precision_may_be_lost notes
#> 1                      FALSE                 FALSE      
rducks_argument_type_mapping(STRUCT(a = INTEGER, b = VARCHAR))
#>                    duckdb_type descriptor_kind r_value_class
#> 1 STRUCT(a INTEGER, b VARCHAR)          struct          list
#>       r_argument_shape special_null_argument         copy_semantics
#> 1 named list of fields                  NULL recursive R allocation
#>   integer_uses_r_double float32_widens_to_r_double precision_may_be_lost
#> 1                 FALSE                      FALSE                 FALSE
#>                     notes
#> 1 recursive field mapping
```
