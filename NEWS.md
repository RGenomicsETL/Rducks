# Rducks 0.0.0.9000

- Added an official in-process queued execution API for scalar UDFs:
  `rducks_enable_inproc()`, `rducks_disable_inproc()`,
  `rducks_inproc_stats()`, and `rducks_inproc_self_test()`. The backend keeps
  all R API work on the recorded main R thread and uses an extension-owned queue
  with timeout/error paths rather than a package-side pump or hidden progress
  callback.
- Added native queue diagnostics and tests covering main-lane queue draining and
  scalar UDF execution through the queued path.
- Split scalar execution and native extension runtime state so UDF metadata uses
  DuckDB C extension bind/init/local-state hooks and per-loaded-database runtime
  entries instead of a singleton connection.
- Initial development scaffold for an R package and DuckDB extension bridge for
  R user-defined functions.
