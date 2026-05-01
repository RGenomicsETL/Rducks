# Convert R date/time values to Rducks scalar-mode shapes

These helpers normalize common R date/time inputs to the R value shapes
used by Rducks scalar-mode marshalling for DuckDB `DATE`, `TIME`,
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
