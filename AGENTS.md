# Rducks Repo Guidelines

Rducks is an R package plus DuckDB extension bridge for registering R UDFs in DuckDB.

## Scope

This repo owns:

- R package wrappers for enabling the extension and registering R UDFs
- native callback token/pump runtime
- DuckDB extension registration and execution bridge
- Rtinycc-generated per-shape UDF wrappers
- optional nanoarrow/Arrow C Data Interface batch UDF paths

## Rules

- Do not manually edit generated `.Rd` files. Update roxygen comments and run `make rd`.
- Keep the native DuckDB extension contract canonical; R wrappers should not redefine SQL semantics.
- Do not call R APIs from DuckDB worker threads. Use main-thread direct calls or queued requests plus a pump.
- Treat callback lifetime explicitly: preserve R functions while native code can call them, and release deterministically.
- Keep Arrow batch paths in-process via Arrow C Data Interface, not Arrow IPC.
- Prefer small staged native modules over a monolithic extension source.

## Architecture notes

- See `docs/ARCHITECTURE.md` for the package/extension split.
- See `docs/COPYING_FROM_DUCKTINYCC.md` for the exact DuckTinyCC pieces to adapt.
- See `docs/NANOARROW.md` for nanoarrow dependency policy.
