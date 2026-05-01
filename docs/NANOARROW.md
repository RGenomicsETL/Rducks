# Nanoarrow

Rducks uses `nanoarrow` as the R-side representation for DuckDB Arrow C Data
arrays and schemas. The R `arrow` package is not a dependency and should not be
required by callback marshalling.

## Why nanoarrow

- R-side external pointer wrappers for Arrow C Data structures
- ownership/release callback conventions
- low-dependency bridge to `ArrowArray`, `ArrowSchema`, and `ArrowArrayStream`
- avoids forcing the full R `arrow` package for low-level C Data Interface paths

## Dependency stance

`nanoarrow` is a runtime dependency (`Imports`) and a C-header dependency
(`LinkingTo`). Callback execution paths must stay within DuckDB Arrow C Data,
nanoarrow, and Rducks' own manual buffer builders for cases where nanoarrow
would otherwise delegate to the R `arrow` package.

## Non-goals

- Do not use Arrow IPC for in-process UDF calls.
- Do not materialize base R data frames just to cross from DuckDB to R when a
  DuckDB Arrow C Data view is enough.
