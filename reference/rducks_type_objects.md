# Rducks DuckDB type descriptors and constructors

Use these descriptors and constructors in
[`rducks_register_scalar_udf()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_scalar_udf.md)
and
[`rducks_register_aggregate()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register_aggregate.md)
to avoid quoted type specifications. Examples include `args = INTEGER`,
`args = c(INTEGER, DOUBLE)`, `args = INTEGER[]`, `args = INTEGER[3]`,
`args = STRUCT(a = INTEGER, b = VARCHAR)`, and
`args = MAP(VARCHAR, INTEGER)`.

## Usage

``` r
rducks_is_type(x)

BOOLEAN

TINYINT

UTINYINT

SMALLINT

USMALLINT

INTEGER

UINTEGER

BIGINT

UBIGINT

FLOAT

DOUBLE

VARCHAR

BLOB

GEOMETRY

VARIANT

DATE

TIME

TIMESTAMP

HUGEINT

UHUGEINT

UUID

INTERVAL

BIT

DECIMAL(width, scale = 0L)

ENUM(levels)

UNION(...)

LIST(type)

ARRAY(type, size)

MAP(key, value)

STRUCT(...)
```

## Format

An object of class `Rducks::rducks_bool_type` (inherits from
`Rducks::rducks_logical_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

An object of class `Rducks::rducks_i8_type` (inherits from
`Rducks::rducks_r_integer_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

An object of class `Rducks::rducks_u8_type` (inherits from
`Rducks::rducks_r_integer_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

An object of class `Rducks::rducks_i16_type` (inherits from
`Rducks::rducks_r_integer_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

An object of class `Rducks::rducks_u16_type` (inherits from
`Rducks::rducks_r_integer_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

An object of class `Rducks::rducks_i32_type` (inherits from
`Rducks::rducks_r_integer_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

An object of class `Rducks::rducks_u32_type` (inherits from
`Rducks::rducks_r_numeric_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

An object of class `Rducks::rducks_i64_type` (inherits from
`Rducks::rducks_exact_integer_scalar_type`,
`Rducks::rducks_scalar_type`, `Rducks::rducks_type`, `list`,
`S7_object`) of length 7.

An object of class `Rducks::rducks_u64_type` (inherits from
`Rducks::rducks_exact_integer_scalar_type`,
`Rducks::rducks_scalar_type`, `Rducks::rducks_type`, `list`,
`S7_object`) of length 7.

An object of class `Rducks::rducks_f32_type` (inherits from
`Rducks::rducks_floating_scalar_type`,
`Rducks::rducks_r_numeric_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

An object of class `Rducks::rducks_f64_type` (inherits from
`Rducks::rducks_floating_scalar_type`,
`Rducks::rducks_r_numeric_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

An object of class `Rducks::rducks_varchar_type` (inherits from
`Rducks::rducks_character_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

An object of class `Rducks::rducks_blob_type` (inherits from
`Rducks::rducks_binary_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

An object of class `Rducks::rducks_geometry_type` (inherits from
`Rducks::rducks_binary_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

An object of class `Rducks::rducks_variant_type` (inherits from
`Rducks::rducks_scalar_type`, `Rducks::rducks_type`, `list`,
`S7_object`) of length 7.

An object of class `Rducks::rducks_date_type` (inherits from
`Rducks::rducks_temporal_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

An object of class `Rducks::rducks_time_type` (inherits from
`Rducks::rducks_temporal_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

An object of class `Rducks::rducks_timestamp_type` (inherits from
`Rducks::rducks_temporal_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

An object of class `Rducks::rducks_hugeint_type` (inherits from
`Rducks::rducks_exact_integer_scalar_type`,
`Rducks::rducks_scalar_type`, `Rducks::rducks_type`, `list`,
`S7_object`) of length 7.

An object of class `Rducks::rducks_uhugeint_type` (inherits from
`Rducks::rducks_exact_integer_scalar_type`,
`Rducks::rducks_scalar_type`, `Rducks::rducks_type`, `list`,
`S7_object`) of length 7.

An object of class `Rducks::rducks_uuid_type` (inherits from
`Rducks::rducks_uuid_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

An object of class `Rducks::rducks_interval_type` (inherits from
`Rducks::rducks_interval_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

An object of class `Rducks::rducks_bit_type` (inherits from
`Rducks::rducks_binary_scalar_type`, `Rducks::rducks_scalar_type`,
`Rducks::rducks_type`, `list`, `S7_object`) of length 7.

## Arguments

- x:

  Object to test with `rducks_is_type()`.

- width, scale:

  DuckDB decimal width and scale for `DECIMAL()`.

- levels:

  Character vector of enum dictionary values for `ENUM()`.

- ...:

  Named field types for `STRUCT()`/`UNION()` or descriptors for
  [`c()`](https://rdrr.io/r/base/c.html).

- type:

  Child type for `LIST()` or `ARRAY()`.

- size:

  Fixed array size for `ARRAY()`.

- key, value:

  Key and value types for `MAP()`.

## Value

A formal S7 `rducks_type` descriptor, or a `rducks_type_list` from
[`c()`](https://rdrr.io/r/base/c.html).

## Examples

``` r
INTEGER
#> <rducks_type:scalar> INTEGER
rducks_is_type(INTEGER)
#> [1] TRUE
rducks_is_type("not a type")
#> [1] FALSE
LIST(VARCHAR)
#> <rducks_type:list> VARCHAR[]
#>   children:
#>     child: VARCHAR
ARRAY(INTEGER, 3L)
#> <rducks_type:array> INTEGER[3]
#>   children:
#>     child: INTEGER
STRUCT(a = INTEGER, b = VARCHAR)
#> <rducks_type:struct> STRUCT(a INTEGER, b VARCHAR)
#>   children:
#>     a: INTEGER
#>     b: VARCHAR
MAP(VARCHAR, DOUBLE)
#> <rducks_type:map> MAP(VARCHAR, DOUBLE)
#>   children:
#>     key: VARCHAR
#>     value: DOUBLE
DECIMAL(10L, 2L)
#> <rducks_type:decimal> DECIMAL(10, 2)
#>   parameters: width=10, scale=2
ENUM(c("small", "medium", "large"))
#> <rducks_type:enum> ENUM('small', 'medium', 'large')
#>   parameters: levels=small,medium,large
UNION(i = INTEGER, s = VARCHAR)
#> <rducks_type:union> UNION(i INTEGER, s VARCHAR)
#>   children:
#>     i: INTEGER
#>     s: VARCHAR
c(INTEGER, DOUBLE, VARCHAR)
#> <rducks_type_list[3]>
#>   1: INTEGER
#>   2: DOUBLE
#>   3: VARCHAR
```
