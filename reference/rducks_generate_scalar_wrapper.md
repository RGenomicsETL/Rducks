# Generate C source for a scalar R UDF wrapper

The generated function has the fixed native ABI used by the Rducks
DuckDB extension:
`bool fn(SEXP fun, void **args, const bool *arg_is_null, void *out_value, bool *out_is_null)`.
The extension handles DuckDB vector access and the generated wrapper
handles only shape-specific R marshalling.

## Usage

``` r
rducks_generate_scalar_wrapper(spec, symbol = NULL)
```

## Arguments

- spec:

  A
  [`rducks_udf_spec()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_udf_spec.md)
  object.

- symbol:

  Optional C symbol name.

## Value

Character scalar C source with attributes `symbol` and `hash`.
