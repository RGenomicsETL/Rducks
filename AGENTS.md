# Rducks Repo Guidelines

Rducks is an R package that builds and loads a DuckDB C extension for
registering R functions as DuckDB SQL UDFs.

## Scope

This repo owns:

- R wrappers for loading/enabling the extension and registering R UDFs
- DuckDB C extension registration, runtime state, SQL surfaces, and callbacks
- execution-plan selection and validation
- scalar and vectorized R UDF marshalling
- type descriptors, value classes, NULL/error semantics, and diagnostics
- native NNG worker transport and the Rducks Quack wire codec (DuckDB
  BinarySerializer subset) for the worker-process data plane

## Rules

- Do not manually edit generated `.Rd` files. Update roxygen comments and run
  `make rd`.
- Keep DuckDB SQL semantics canonical in the native extension. R wrappers should
  validate and select plans, not redefine DuckDB behavior.
- Do not call R APIs from DuckDB worker threads. Use only the recorded R thread
  directly or the explicit extension-owned in-process queue.
- Do not silently change execution plans. Unsupported plan/type/mode
  combinations must fail instead of falling back to another engine.
- Marshal in-process by materializing DuckDB vectors to SEXPs directly in
  extension C. Use the Quack wire codec only for bytes that intentionally cross
  a process/transport boundary.
- Treat R function lifetime explicitly. Preserve objects while native metadata
  can call them; release only through paths that are safe for the R thread.
- Keep docs factual. Mark unsupported and experimental behavior plainly; remove
  old design notes once they no longer describe the code.

## Style discipline

- C: small functions, explicit ownership, checked allocation/size arithmetic,
  single cleanup paths where useful, and byte-level validation at boundaries.
  Do not let borrowed DuckDB vectors, transient `SEXP`s, or unchecked raw buffers
  escape their lifetime.
- R: package-style APIs with clear argument validation, vector semantics,
  explicit condition messages, minimal global state, and no hidden side effects
  in examples or tests.

## Architecture notes

- `docs/ARCHITECTURE.md`: package/extension split and thread boundaries.
- `docs/BUILD.md`: install-time extension build and DuckDB header vendoring.
- `docs/EXECUTION_PLANS.md`: plan semantics and strict-plan rule.
- `docs/SUPPORT_MATRIX.md`: supported plan/type combinations and ownership
  notes.
