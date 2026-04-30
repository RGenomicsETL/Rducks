# Soft-unregister an Rducks registration

DuckDB currently registers extension scalar functions as internal
catalog entries, so SQL `DROP FUNCTION` cannot remove them.
`rducks_unregister()` replaces the matching overload with an inactive
stub, releases Rducks' R-side callback token, and drops the package
registry reference to the compiled wrapper. Future SQL calls to the same
overload report that the UDF was unregistered.

## Usage

``` r
rducks_unregister(registration)
```

## Arguments

- registration:

  A
  [`rducks_register()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_register.md)
  result.

## Value

`NULL`, invisibly.
