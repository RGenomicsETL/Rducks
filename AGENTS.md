# Rducks Repo Guidelines

Rducks is an R package plus DuckDB extension bridge for registering R UDFs in DuckDB.

## Scope

This repo owns:

- R package wrappers for enabling the extension and registering R UDFs
- DuckDB extension registration and execution bridge
- native scalar-mode UDF registration and callback marshalling
- nanoarrow scalar adapter over DuckDB Arrow C Data

## Rules

- Do not manually edit generated `.Rd` files. Update roxygen comments and run `make rd`.
- Keep the native DuckDB extension contract canonical; R wrappers should not redefine SQL semantics.
- Do not call R APIs from DuckDB worker threads. Use calling-R-thread direct calls or queued requests.
- Treat callback lifetime explicitly: preserve R functions while native code can call them.
- Keep marshalling paths in-process via DuckDB Arrow C Data and nanoarrow, not Arrow IPC.
- Prefer small staged native modules over a monolithic extension source.

## Architecture notes

- See `docs/ARCHITECTURE.md` for the package/extension split.
- See `docs/BUILD.md` for the install-time DuckDB extension build and header-fetch workflow.
- See `docs/NANOARROW.md` for nanoarrow dependency policy.
