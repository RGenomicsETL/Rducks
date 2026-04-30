# Compile a scalar wrapper with Rtinycc

Compile a scalar wrapper with Rtinycc

## Usage

``` r
rducks_compile_scalar_wrapper(spec)
```

## Arguments

- spec:

  A
  [`rducks_udf_spec()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_udf_spec.md)
  object.

## Value

Object containing the Rtinycc state, symbol pointer, symbol name, and
generated source. Keep this object alive for as long as DuckDB may call
the registered UDF.
