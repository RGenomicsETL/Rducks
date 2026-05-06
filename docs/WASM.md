# Rducks WebAssembly / webR Support Level

Rducks contains build scaffolding for WebAssembly-oriented experiments, but the
current supported runtime target is a regular R process with a DuckDB extension
loaded from the local filesystem.

Current status:

- WebAssembly builds are **experimental**.
- There is no committed webR runtime smoke test yet.
- Same-process queued execution relies on native thread/condition-variable
  primitives and a recorded main R thread; browser/webR runtimes may not provide
  equivalent threading or blocking semantics.
- `arrow_ipc + multiprocess_parallel` relies on R worker processes via the
  generic `future` path and should not be assumed to work in webR.
- The package should not claim browser/webR runtime support until a CI smoke test
  loads the extension, enables Rducks, registers at least one UDF, and executes a
  query inside the target runtime.

Checklist before changing this status:

1. Build the extension and R package for the target wasm/webR runtime.
2. Verify the extension artifact can be found and loaded by DuckDB in that
   runtime.
3. Run a minimal `rducks_enable()` + `rducks_register()` + SQL query smoke test.
4. Run at least one no-hidden-fallback check for the claimed execution plan.
5. Document unsupported plans explicitly, especially same-process queued and
   multiprocess worker modes.
