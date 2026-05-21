# Convert R date/time values to Rducks scalar-UDF shapes

These helpers normalize common R date/time inputs to the R value shapes
used by Rducks DuckDB scalar-UDF marshalling for `DATE`, `TIME`,
`TIMESTAMP`, and `INTERVAL` values.

## Usage

``` r
rducks_as_date(x, tz = "UTC", origin = "1970-01-01")

rducks_as_timestamp(x, tz = "UTC", origin = "1970-01-01")

rducks_as_time(x, tz = "UTC")

rducks_as_interval(
  x,
  units = c("secs", "mins", "hours", "days", "weeks"),
  months = 0L,
  days = 0L
)

rducks_interval_between(start, end, tz = "UTC")
```

## Arguments

- x, start, end:

  R date/time value. Supported inputs include `Date`,
  `POSIXct`/`POSIXlt`, `difftime`, numeric seconds where documented, and
  character strings accepted by base R or `HH:MM:SS[.ffffff]` for times.
  Numeric `DATE`/`TIMESTAMP` inputs must be finite or missing. DuckDB
  `TIME` inputs must be finite seconds in `[0, 86400)` or missing.

- tz:

  Time zone used when converting date-times.

- origin:

  Origin for numeric timestamp/date input.

- units:

  Units for numeric interval input.

- months, days:

  Extra interval month/day components for `rducks_as_interval()`.

  Numeric and `difftime` intervals are rounded to the nearest
  microsecond before constructing
  [`rducks_interval()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_interval.md).

## Value

`rducks_as_date()` returns a `Date` vector; `rducks_as_time()` returns
numeric seconds since midnight; `rducks_as_timestamp()` returns
`POSIXct`; `rducks_as_interval()` and `rducks_interval_between()` return
`rducks_interval`.

## Examples

``` r
rducks_as_date(as.Date("2024-01-15"))
#> [1] "2024-01-15"
rducks_as_date("2024-01-15")
#> [1] "2024-01-15"
rducks_as_timestamp(as.POSIXct("2024-01-15 12:00:00", tz = "UTC"))
#> [1] "2024-01-15 12:00:00 UTC"
rducks_as_time("08:30:00")
#> [1] 30600
rducks_as_interval(3600, units = "secs")
#> <rducks_interval[1]>
#>  months days     micros
#>       0    0 3600000000
rducks_interval_between(
  as.POSIXct("2024-01-01", tz = "UTC"),
  as.POSIXct("2024-01-02", tz = "UTC")
)
#> <rducks_interval[1]>
#>  months days      micros
#>       0    0 86400000000
```
