# Register an R callback token

Registers an R function with the native Rducks callback registry. The
returned external pointer preserves the function until it is closed or
garbage collected.

## Usage

``` r
rducks_callback(fun)
```

## Arguments

- fun:

  R function.

## Value

External pointer with class `rducks_callback`.
