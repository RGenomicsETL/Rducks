# Rducks WebAssembly / webR Support Level

Rducks contains build scaffolding for WebAssembly-oriented experiments, but the
current supported runtime target is a regular R process with a DuckDB extension
loaded from the local filesystem.

Current status:

- WebAssembly builds are **experimental**.
- A browser webR runtime smoke harness is committed in
  `scripts/start_webr_local_test.sh`, `scripts/webr-local-test.html`, and
  `scripts/run_webr_browser_smoke.mjs`.
- `.github/workflows/webr-smoke.yaml` runs the harness with Chromium/Playwright
  against a locally served webR package repository on push, pull request, and
  manual dispatch.
- Same-process queued execution relies on native thread/condition-variable
  primitives and a recorded main R thread; browser/webR runtimes may not provide
  equivalent threading or blocking semantics.
- `arrow_ipc + multiprocess_parallel` relies on R worker processes via the
  generic `future` path and should not be assumed to work in webR.
- The package should not claim browser/webR runtime support unless the CI smoke
  test is green for the target runtime and proves extension load, UDF
  registration, and query execution. If the webR DuckDB runtime lacks extension
  support, the smoke reports an explicit skip for that DuckDB-specific portion.

Local smoke workflow:

```sh
scripts/start_webr_local_test.sh
```

Then open the printed browser URL and click **Run smoke test**. For an automated
browser run against that local server, use:

```sh
npm install --no-save playwright
npx playwright install chromium
node scripts/run_webr_browser_smoke.mjs
```

The page installs
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
5. Keep the browser smoke workflow green for the target runtime instead of
   relying only on the local harness.
6. Document unsupported plans explicitly, especially same-process queued and
   multiprocess worker modes.
