# Construct DuckDB INTERVAL values

DuckDB intervals have three independent components: months, days, and
microseconds. This class preserves those components instead of
collapsing an interval to a single duration.

## Usage

``` r
rducks_interval(months = 0L, days = 0L, micros = 0L)
```

## Arguments

- months:

  Integer month components.

- days:

  Integer day components.

- micros:

  Integer microsecond components. Values outside R's exact numeric range
  should be supplied as character strings.

## Value

Object of class `rducks_interval`.

## Examples

``` r
rducks_interval(months = 1L, days = 15L, micros = 0L)
#> <rducks_interval[1]>
#>  months days micros
#>       1   15      0
rducks_interval(days = c(1L, 2L, NA_integer_))
#> <rducks_interval[3]>
#>  months days micros
#>       0    1      0
#>       0    2      0
#>       0   NA      0
```
