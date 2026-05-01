# Pump pending Rducks callback requests

Worker-thread DuckDB UDF requests are drained internally by the loaded
Rducks extension whenever execution reaches the calling R thread. This
helper is kept as a public pump hook and currently returns the number of
package-local requests processed by the R package runtime.

## Usage

``` r
rducks_pump()
```

## Value

Integer count of package-local requests processed.
