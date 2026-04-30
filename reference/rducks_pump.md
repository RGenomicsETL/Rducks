# Pump pending Rducks callback requests

This is the planned main-R-thread pump for native DuckDB worker
requests. It currently errors because the DuckDB extension request queue
is not implemented yet.

## Usage

``` r
rducks_pump()
```

## Value

Currently does not return; errors until the native queue exists.
