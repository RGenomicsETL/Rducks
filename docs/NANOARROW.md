# Nanoarrow

Rducks uses `nanoarrow` for R-side Arrow C Data arrays and schemas. The R
`arrow` package is not a dependency.

## Role in Rducks

- wrap `ArrowArray`, `ArrowSchema`, and `ArrowArrayStream` pointers on the R side
- follow Arrow C Data ownership and release-function conventions
- provide a low-dependency bridge for the `arrow_r` marshalling path
- support manual Rducks conversion code for DuckDB-specific types where needed

## Dependency stance

`nanoarrow` is both a runtime dependency (`Imports`) and a C-header dependency
(`LinkingTo`). Rducks marshalling should stay within DuckDB Arrow C Data,
nanoarrow, and Rducks-owned conversion/buffer code.

## Boundaries

- Do not require the full R `arrow` package for UDF marshalling.
- Do not use Arrow IPC for ordinary in-process UDF callbacks.
- Do not materialize data frames merely to cross the DuckDB/R boundary when an
  Arrow C Data view plus explicit conversion is enough.
