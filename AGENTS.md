# Rducks Repo Guidelines

Rducks is an R package plus DuckDB extension bridge for registering R UDFs in DuckDB.

## Scope

This repo owns:

- R package wrappers for enabling the extension and registering R UDFs
- DuckDB extension registration and execution bridge
- native scalar-mode UDF registration and R function marshalling
- nanoarrow scalar adapter over DuckDB Arrow C Data

## Rules

- Do not manually edit generated `.Rd` files. Update roxygen comments and run `make rd`.
- Keep the native DuckDB extension contract canonical; R wrappers should not redefine SQL semantics.
- Do not call R APIs from DuckDB worker threads. Use calling-R-thread direct calls or the explicit extension-owned in-process queue; never use a package-side pump or hidden DuckDB progress callback.
- Treat R function lifetime explicitly: preserve R functions while native code can call them.
- Keep in-process marshalling paths via DuckDB Arrow C Data and nanoarrow, not Arrow IPC.
- Use Arrow IPC only for explicit serialized/out-of-process transports such as a future mirai-backed compute plan.
- Prefer small staged native modules over a monolithic extension source.

## Style discipline

- Write C as a BSD kernel programmer rather than a Java programmer that failed upwards; this is about ownership, control flow, allocation, error paths, and byte-level clarity, not just indentation.
- Write R as a r-lib programmer rather than a Python programmer that failed upwards; this is about API shape, vector semantics, conditions, dependencies, and package discipline, not just indentation.

## Architecture notes

- See `docs/ARCHITECTURE.md` for the package/extension split.
- See `docs/BUILD.md` for the install-time DuckDB extension build and header-fetch workflow.
- See `docs/NANOARROW.md` for nanoarrow dependency policy.
