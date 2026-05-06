# Rducks DuckDB type objects and constructors

Use these objects and constructors in
[`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md)
to avoid string type specifications. Examples include `args = INTEGER`,
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

An object of class `rducks_bool_type` (inherits from
`rducks_logical_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

An object of class `rducks_i8_type` (inherits from
`rducks_r_integer_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

An object of class `rducks_u8_type` (inherits from
`rducks_r_integer_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

An object of class `rducks_i16_type` (inherits from
`rducks_r_integer_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

An object of class `rducks_u16_type` (inherits from
`rducks_r_integer_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

An object of class `rducks_i32_type` (inherits from
`rducks_r_integer_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

An object of class `rducks_u32_type` (inherits from
`rducks_r_numeric_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

An object of class `rducks_i64_type` (inherits from
`rducks_exact_integer_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

An object of class `rducks_u64_type` (inherits from
`rducks_exact_integer_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

An object of class `rducks_f32_type` (inherits from
`rducks_floating_scalar_type`, `rducks_r_numeric_scalar_type`,
`rducks_scalar_type`, `rducks_type`, `list`, `S7_object`) of length 1.

An object of class `rducks_f64_type` (inherits from
`rducks_floating_scalar_type`, `rducks_r_numeric_scalar_type`,
`rducks_scalar_type`, `rducks_type`, `list`, `S7_object`) of length 1.

An object of class `rducks_varchar_type` (inherits from
`rducks_character_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

An object of class `rducks_blob_type` (inherits from
`rducks_binary_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

An object of class `rducks_date_type` (inherits from
`rducks_temporal_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

An object of class `rducks_time_type` (inherits from
`rducks_temporal_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

An object of class `rducks_timestamp_type` (inherits from
`rducks_temporal_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

An object of class `rducks_hugeint_type` (inherits from
`rducks_exact_integer_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

An object of class `rducks_uhugeint_type` (inherits from
`rducks_exact_integer_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

An object of class `rducks_uuid_type` (inherits from
`rducks_uuid_scalar_type`, `rducks_scalar_type`, `rducks_type`, `list`,
`S7_object`) of length 1.

An object of class `rducks_interval_type` (inherits from
`rducks_interval_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

An object of class `rducks_bit_type` (inherits from
`rducks_binary_scalar_type`, `rducks_scalar_type`, `rducks_type`,
`list`, `S7_object`) of length 1.

## Arguments

- x:

  Object to test with `rducks_is_type()`.

- width, scale:

  DuckDB decimal width and scale for `DECIMAL()`.

- levels:

  Character vector of enum dictionary values for `ENUM()`.

- ...:

  Named field types for `STRUCT()`/`UNION()` or type objects for
  [`c()`](https://rdrr.io/r/base/c.html).

- type:

  Child type for `LIST()` or `ARRAY()`.

- size:

  Fixed array size for `ARRAY()`.

- key, value:

  Key and value types for `MAP()`.

## Value

A formal S7/S3-compatible `rducks_type` object, or a `rducks_type_list`
from [`c()`](https://rdrr.io/r/base/c.html).
