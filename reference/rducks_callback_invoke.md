# Invoke an Rducks callback token

This helper is intended for tests and for validating marshalling
behavior. In the DuckDB extension, callbacks are normally invoked from
native trampoline code or through the main-thread pump.

## Usage

``` r
rducks_callback_invoke(callback, args = list())
```

## Arguments

- callback:

  A callback returned by
  [`rducks_callback()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_callback.md).

- args:

  List of R arguments.

## Value

Callback result.
