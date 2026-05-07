# Rducks WebAssembly / webR Support Level

Rducks contains build scaffolding for WebAssembly-oriented experiments, but the
current supported runtime target is a regular R process with a DuckDB extension
loaded from the local filesystem.

Current status:

- WebAssembly builds are **experimental**.
- A local browser webR runtime smoke harness is committed in
  `scripts/start_webr_local_test.sh` and `scripts/webr-local-test.html`.
- Same-process queued execution relies on native thread/condition-variable
  primitives and a recorded main R thread; browser/webR runtimes may not provide
  equivalent threading or blocking semantics.
- `arrow_ipc + multiprocess_parallel` relies on R worker processes via the
  generic `future` path and should not be assumed to work in webR.
- The package should not claim browser/webR runtime support until the smoke test
  is also run in CI and proves extension load, UDF registration, and query
  execution inside the target runtime.

Local smoke workflow:

```sh
scripts/start_webr_local_test.sh
```

Then open the printed browser URL and click **Run smoke test**. The page installs
the locally built `.tgz` from a tiny local webR repository, loads Rducks in webR,
runs public type/mode helpers, and attempts a minimal `rducks_enable()` +
`rducks_register()` + SQL query when the webR DuckDB runtime supports extension
loading. If DuckDB is unavailable in that runtime, the page reports an explicit
skip instead of treating package-load success as extension support.

Checklist before changing this status:

1. Build the extension and R package for the target wasm/webR runtime.
2. Verify the extension artifact can be found and loaded by DuckDB in that
   runtime.
3. Run a minimal `rducks_enable()` + `rducks_register()` + SQL query smoke test.
4. Run at least one no-hidden-fallback check for the claimed execution plan.
5. Add the smoke test to CI instead of relying only on the local browser harness.
6. Document unsupported plans explicitly, especially same-process queued and
   multiprocess worker modes.
