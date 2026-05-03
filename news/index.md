# Changelog

## Rducks 0.0.0.9000

- Added `mode = "vectorized"` for R UDFs that should be called once per
  DuckDB chunk with vector/list-column arguments. The vectorized adapter
  uses the same Arrow C Data/nanoarrow bridge as scalar mode, enforces
  return length, defines default vs special NULL handling, and is
  covered by runtime tests.
- Added an official in-process queued execution API for scalar UDFs:
  [`rducks_enable_inproc()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_enable_inproc.md),
  [`rducks_disable_inproc()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_disable_inproc.md),
  [`rducks_inproc_stats()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_inproc_stats.md),
  and
  [`rducks_inproc_self_test()`](https://sounkou-bioinfo.github.io/Rducks/reference/rducks_inproc_self_test.md).
  The backend keeps all R API work on the recorded main R thread and
  uses an extension-owned queue with timeout/error paths rather than a
  package-side pump or hidden progress callback.
- Added native queue diagnostics and tests covering main-lane queue
  draining and scalar UDF execution through the queued path.
- Split scalar execution and native extension runtime state so UDF
  metadata uses DuckDB C extension bind/init/local-state hooks and
  per-loaded-database runtime entries instead of a singleton connection.
- Initial development scaffold for an R package and DuckDB extension
  bridge for R user-defined functions.
