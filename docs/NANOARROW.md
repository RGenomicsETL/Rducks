# Nanoarrow Plan

Rducks should use nanoarrow for the in-process Arrow C Data Interface parts, not
for the scalar MVP.

## Why nanoarrow

- R-side external pointer wrappers for Arrow C structures
- ownership/release callback conventions
- low-dependency bridge to `ArrowArray`, `ArrowSchema`, and `ArrowArrayStream`
- avoids forcing the full Arrow R package for low-level C Data Interface paths

## Dependency stance

For the initial scalar package, `nanoarrow` is optional (`Suggests`). Once native
Arrow batch UDF code includes nanoarrow headers, move it to `LinkingTo` and, if
R wrappers require it at runtime, `Imports`.

## Non-goals

- Do not use Arrow IPC for in-process UDF calls.
- Do not materialize base R data frames just to cross from DuckDB to R when an
  Arrow C Data Interface view is enough.
