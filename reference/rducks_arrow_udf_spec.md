# Plan an Arrow-batch UDF shape

Arrow/nanoarrow support is intentionally kept as an in-process Arrow C
Data Interface path, not an IPC path. This helper records the intended
batch UDF shape before native registration is wired in.

## Usage

``` r
rducks_arrow_udf_spec(name, fun, schema = NULL)
```

## Arguments

- name:

  SQL function name.

- fun:

  R function that will receive or return Arrow-compatible objects.

- schema:

  Optional nanoarrow schema object or schema descriptor.

## Value

A list of class `rducks_arrow_udf_spec`.
