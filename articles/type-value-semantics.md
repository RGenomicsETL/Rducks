# Type and Value Semantics

Rducks keeps SQL type semantics explicit. DuckDB owns binding and
execution; Rducks maps DuckDB values into R values, calls the R
function, and writes values back to DuckDB with the declared result
type.

## Function kind, scalar-UDF mode, and execution plan

Three concepts are intentionally separate:

- **DuckDB function kind**: scalar UDF, aggregate function, or table
  function.
- **Scalar-UDF evaluation mode**: `mode = "scalar"` calls R once per
  row; `mode = "vectorized"` calls R once per DuckDB chunk.
- **Scalar-UDF execution plan**: in-process (`transport = "inproc"`) or
  worker-process (`transport = "ipc"`) evaluation.

Changing a connection’s default execution plan affects future scalar-UDF
registrations and the matching native runtime backend; it does not
rewrite an existing scalar UDF to a different transport.

``` r

library(DBI)
library(duckdb)
library(Rducks)

con <- dbConnect(duckdb(config = list(allow_unsigned_extensions = "true")))
#> duckdb is keeping downloaded extensions in a temporary directory:
#> ℹ /tmp/RtmpfxZFnY/duckdb/extensions
#> This is removed when the R session ends, so extensions are re-downloaded each session.
#> ℹ To keep them, point `options(duckdb.extension_directory =)` or the `DUCKDB_EXTENSION_DIRECTORY` environment variable at a permanent path.
rducks_enable(con, threads = "single")
```

## Declared descriptors

Rducks descriptors describe DuckDB logical types, including primitive,
exact, and composite values.

``` r

primitive <- list(INTEGER, DOUBLE, BOOLEAN, VARCHAR)
exact <- list(UUID, HUGEINT, DECIMAL(18, 4), INTERVAL, BIT)
semi_structured <- list(GEOMETRY, VARIANT)
composite <- list(
  INTEGER[],
  ARRAY(DOUBLE, 3),
  STRUCT(id = INTEGER, label = VARCHAR),
  MAP(VARCHAR, DOUBLE),
  UNION(i = INTEGER, s = VARCHAR)
)
```

Declared scalar-UDF arguments pin the SQL signature:

``` r

rducks_register_scalar_udf(
  con,
  name = "r_add_one",
  fun = function(x) x + 1L,
  args = INTEGER,
  returns = INTEGER
)
#> <rducks_scalar_udf_registration>
#>   registered:      yes
#>   name:            r_add_one
#>   evaluation_mode: scalar
#>   plan:            direct+serial
#>   signature:       r_add_one(INTEGER) -> INTEGER
```

Omitting `args` registers a dynamic DuckDB varargs function. At bind
time, DuckDB supplies the concrete logical types for the SQL call, and
Rducks uses those bound types for the same input materialization it
would use for explicit `args`.

``` r

rducks_register_scalar_udf(
  con,
  name = "r_payload_label",
  fun = function(payload) paste(payload$label, payload$x, sep = ":"),
  returns = VARCHAR
)
#> <rducks_scalar_udf_registration>
#>   registered:      yes
#>   name:            r_payload_label
#>   evaluation_mode: scalar
#>   plan:            direct+serial
#>   signature:       r_payload_label(...) -> VARCHAR

DBI::dbGetQuery(con, "
  SELECT r_payload_label(struct_pack(x := 3::INTEGER, label := 'a')) AS label
")
#>   label
#> 1   a:3
```

Use `args = NULL` for a true zero-argument UDF.

## NULL handling

`null_handling = "default"` follows DuckDB’s default scalar-UDF
contract: if a top-level input is SQL `NULL`, DuckDB produces SQL `NULL`
without calling R.

`null_handling = "special"` passes top-level SQL `NULL` inputs through
to R as type-specific missing values so the R function can decide what
to return.

``` r

rducks_register_scalar_udf(
  con,
  name = "r_null_special",
  fun = function(x) if (is.na(x)) 5L else x,
  args = INTEGER,
  returns = INTEGER,
  null_handling = "special"
)
#> <rducks_scalar_udf_registration>
#>   registered:      yes
#>   name:            r_null_special
#>   evaluation_mode: scalar
#>   plan:            direct+serial
#>   signature:       r_null_special(INTEGER) -> INTEGER

DBI::dbGetQuery(con, "SELECT r_null_special(NULL::INTEGER) AS x")
#>   x
#> 1 5
```

Nested NULLs are part of the nested value. Scalar children usually
become typed `NA` values, while nested composite NULLs become `NULL`.

## Error handling and side effects

`exception_handling = "rethrow"` makes R errors fail the SQL query.
Other error handling modes are explicit choices and should be tested
with the declared return type.

Mark functions with `side_effects = TRUE` when they depend on counters,
randomness, time, I/O, mutation, sleeps, external state, or diagnostics.
Without that flag, DuckDB may treat a scalar UDF as pure enough for
ordinary SQL optimization.

## Runtime reference tables

The package exports compact reference tables so tests and documentation
can stay aligned with the implemented semantics.

``` r

rducks_mode_semantics()[, c("mode", "call_granularity", "input_shape")]
#>         mode            call_granularity
#> 1     scalar          one R call per row
#> 2 vectorized one R call per DuckDB chunk
#>                                                               input_shape
#> 1 one scalar/composite R value per declared or dynamically bound argument
#> 2     one R vector/list-column per declared or dynamically bound argument

rducks_value_semantics()[
  rducks_value_semantics()$duckdb_type %in% c("INTEGER", "VARCHAR", "GEOMETRY", "VARIANT", "STRUCT"),
  c("duckdb_type", "r_value_class", "special_null_argument")
]
#>    duckdb_type  r_value_class special_null_argument
#> 6      INTEGER        integer           NA_integer_
#> 12     VARCHAR      character         NA_character_
#> 14    GEOMETRY            raw                  NULL
#> 15     VARIANT rducks_variant                  NULL

rducks_argument_type_mapping(list(
  INTEGER,
  UUID,
  DECIMAL(10, 2),
  STRUCT(a = INTEGER[])
))
#>           duckdb_type descriptor_kind  r_value_class      r_argument_shape
#> 1             INTEGER          scalar        integer        integer scalar
#> 2                UUID          scalar    rducks_uuid    rducks_uuid scalar
#> 3      DECIMAL(10, 2)         decimal rducks_decimal rducks_decimal scalar
#> 4 STRUCT(a INTEGER[])          struct           list  named list of fields
#>   special_null_argument           copy_semantics integer_uses_r_double
#> 1           NA_integer_             boxed scalar                 FALSE
#> 2                  NULL boxed exact Rducks value                 FALSE
#> 3                  NULL boxed exact Rducks value                 FALSE
#> 4                  NULL   recursive R allocation                 FALSE
#>   float32_widens_to_r_double precision_may_be_lost
#> 1                      FALSE                 FALSE
#> 2                      FALSE                 FALSE
#> 3                      FALSE                 FALSE
#> 4                      FALSE                 FALSE
#>                           notes
#> 1                              
#> 2      exact Rducks value class
#> 3 exact fixed-point value class
#> 4       recursive field mapping
```
