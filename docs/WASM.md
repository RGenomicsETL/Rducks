# WebAssembly / webR Status

Rducks has WebAssembly-oriented build and smoke-test scaffolding, but the
supported runtime target is a regular R process that can load the package-managed
DuckDB extension from the local filesystem.

## Current status

- WebAssembly/webR use is experimental.
- The browser smoke harness lives in:
  - `scripts/start_webr_local_test.sh`
  - `scripts/webr-local-test.html`
  - `scripts/run_webr_browser_smoke.mjs`
- `.github/workflows/webr-smoke.yaml` runs that harness with Chromium/Playwright.
- Passing package-load checks are not the same as DuckDB extension support.
- Same-process queued execution depends on native threading/blocking primitives.
- The worker-process `ipc` transport depends on worker processes and
  NNG; do not assume it would work in browser/webR runtimes.

## Local smoke

```sh
scripts/start_webr_local_test.sh
```

Open the printed browser URL and click **Run smoke test**. For an automated
browser run against the local server:

```sh
npm install --no-save playwright
npx playwright install chromium
node scripts/run_webr_browser_smoke.mjs
```

## Claiming support

Do not claim webR/browser support unless the target runtime proves all of the
following:

1. Rducks package load.
2. DuckDB availability in that runtime.
3. Rducks extension artifact discovery and load.
4. `rducks_enable()`.
5. Scalar-UDF registration and a SQL query using that UDF.
6. A strict-plan counter check for each claimed execution plan.

Unsupported plans must be documented explicitly.
