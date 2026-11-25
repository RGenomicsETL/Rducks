# duckdb-r guard companion for managed streaming

The managed `concurrent_inproc` query stream needs the capability supplied by
[`duckdb-r-off-main-guards-v2.0.0.patch`](duckdb-r-off-main-guards-v2.0.0.patch).
This is a reviewable companion patch against duckdb-r 2.0.0, proposed upstream
in [duckdb-r#3084](https://github.com/duckdb/duckdb-r/issues/3084) and not yet
accepted. Rducks rejects managed stream startup when
the capability is absent; ordinary serial and IPC execution remain available.

## Contract and scope

duckdb-r 2.0.0 records R's thread when the package loads (`OnRThread()`). Before
touching R, the patched native callbacks reject calls from another thread with a
DuckDB exception. The source guards cover environment replacement scans, matched
Arrow replacement scans and R Arrow schema/stream factories. These checks matter
because replacement scans belong to the database and are visible to the
extension's native connection, including when the caller's temporary views are
not.

After database startup, the package registers three native C-callables. They are
internal integration endpoints, not user-facing APIs, and none of them enters R:

```c
/* R_GetCCallable("duckdb", "duckdb_r_off_main_guard_version") */
typedef uint32_t (*duckdb_r_off_main_guard_version_fn)(void);
/* Returns 3 for this patch. */

/* R_GetCCallable("duckdb", "duckdb_r_native_driver_enter") */
/* R_GetCCallable("duckdb", "duckdb_r_native_driver_exit") */
typedef void (*duckdb_r_native_driver_mark_fn)(void);
```

Rducks calls `enter` before it starts the helper thread of a managed stream and
`exit` after it has joined that thread. Between the two, duckdb-r refuses R
data-frame binding off R's thread: that bind builds cpp11 vectors, which would
race with R's allocator while R's thread is live. The marker is a process-wide
count. It changes no database setting.

Stock duckdb-r and companions below version 3 fail closed when a managed stream
opens.

The companion does not lock `threads` or any other setting. Do not change
`threads` or `external_threads` through SQL while a managed stream is open, on
any connection to that database. Changing the thread count joins every DuckDB
worker. A worker can wait for R to run a scalar UDF, also between two fetches
(observed with a `UNION ALL` stream at `threads = 2` on DuckDB 2.0.0). R does
not serve callbacks inside `SET`, so that worker can never be joined and the R
process hangs without a way to interrupt it. Close the stream first. Rducks'
own entry points (`rducks_enable()`, `rducks_enable_inproc()`,
`rducks_set_execution_plan()`) reject the change while a stream is open.

This capability means those R-backed binding paths fail before entering R from
the managed helper. It does not marshal R-backed tables or Arrow callbacks to R,
make arbitrary R extensions safe on workers, or expose a borrowed connection.
Managed streaming uses Rducks' database-scoped native connection. Caller-local
temporary objects, transactions and session settings are not transparently
shared. Ordinary DBI execution still needs upstream integration that retains
the caller's connection/result and services R callbacks and interrupts throughout
execution, fetch and teardown. The upstream
[producer-thread plan](https://github.com/duckdb/duckdb-r/blob/v1.5.6/plan/PLAN-streaming-thread.md) (duckdb-r v1.5.6)
separately defers asynchronous open/execute and a binding-complete barrier.

## Pinned sources

The patch changes five source files, with no generated cpp11 changes. Its base is
the CRAN duckdb 2.0.0 source package, built against the official DuckDB v2.0.0
shared library; upstream configure checks that both embed the same core commit.

| Input | SHA-256 |
| --- | --- |
| [duckdb_2.0.0.tar.gz](https://cran.r-project.org/src/contrib/duckdb_2.0.0.tar.gz) | `23db64ca8054c7984dba06958ae9d530579cb7430831ac4f503f33a44f013741` |
| [duckdb-shared-libs-linux-amd64.tar.gz](https://github.com/duckdb/duckdb/releases/download/v2.0.0/duckdb-shared-libs-linux-amd64.tar.gz) | `993ad89e7dfca66cd6da994c2cad090c2fc160ddf9f550498a098ab4bb13cfb1` |
| Companion patch | `f47f6845b0277e0339f01e9b77b5da3648115434319d8c1f7686ba5e69a4dc15` |

The installer falls back to the CRAN version archive when the current-source
URL expires. Every downloaded file must match its pinned checksum.

## Reproduce on Linux amd64

Prerequisites are R 4.2 or newer with DBI installed, a C/C++17 build toolchain,
`make`, `curl`, `git`, `tar`, `xz`, `sha256sum`, and `strings` (binutils).
This recipe was exercised with R 4.6.2 on Linux amd64. The source patch does not
depend on Linux APIs, but macOS and Windows have not been tested. The binary
recipe intentionally accepts Linux amd64 only.

From the Rducks checkout, choose a separate output library and an empty build
directory. Paths must not contain whitespace because upstream configure writes
them into linker flags. Existing ordinary duckdb installations are preserved;
the installer refuses an output library that already contains duckdb.

```sh
tools/compat/install-guarded-duckdb.sh \
  "$PWD/.local/r-library-guarded" \
  "$PWD/.local/duckdb-guarded-build"
```

The installer verifies archives, applies the patch with `git apply --check`, and
uses duckdb-r's supported system-library build:

```sh
TAR_OPTIONS=--no-same-owner \
  DUCKDB_R_USE_SYSTEM_LIB=1 \
  DUCKDB_R_LIB_DIR="$build_dir/libduckdb" \
  MAKEFLAGS=-j2 \
  R CMD INSTALL --library="$output_library" --no-byte-compile .
```

Upstream configure checks that the official `libduckdb.so` matches the exact
vendored core commit. No ABI check is bypassed, and no private connection pointer
is cast. Only R glue is compiled. The installed package uses an absolute runtime
library path: **retain the build directory's `libduckdb` subdirectory**. This is a
development/CI recipe, not a portable binary distribution. The script retains
`install.log`, source and objects, and verifies a SQL result and the actual
versioned C-callable before reporting success. `MAKEFLAGS` may be supplied to
change the default two compilation jobs.

## Managed and stock verification

Use fresh R processes to select a dependency. A loaded stock duckdb namespace
cannot be replaced by changing `.libPaths()` in that process. Put the guarded
library before the ordinary dependency library; if Rducks is installed separately,
put its library first. For example, after installing Rducks with its development
surfaces enabled:

```sh
R_LIBS_USER="$rducks_library:$guarded_library:$ordinary_library" \
  RDUCKS_DEV_SURFACES=true \
  Rscript -e 'for (f in c("test_query_stream_driver.R", "test_query_stream_host_guards.R", "test_query_stream_runtime_guards.R")) { x <- tinytest::run_test_file(file.path("inst/tinytest", f)); print(x); stopifnot(all(as.data.frame(x)$result)) }'
```

`test_query_stream_host_guards.R` covers missing-name replacement and persistent
R data-frame view rejection, main-thread access, and reuse after failed binding.
It also covers registered Arrow input when the optional Arrow package is
installed. `test_query_stream_runtime_guards.R` checks bootstrap after manual
extension loading, configuration checks for a second connection, final-anchor
release, and file-backed shutdown followed by stale-handle close/GC and reopen.
The lifecycle test covers scalar queue execution, error/reentrancy,
early close, garbage collection and reuse. The native SIGINT harness provides
separate interrupt/cleanup checks; see `test/native/run_managed_stream_interrupt.py`.

`python3 test/native/run_managed_stream_configuration.py` uses the same library
environment and runs fresh R processes with a 120-second deadline and forced
kill/reap on failure. It checks that open, failed, abandoned and released streams
leave every setting as found, that a configuration lock set by the user is kept
as is, that Rducks' own configuration entry points reject calls from a stream
callback, and that the thread count can change after streams of four query
shapes have closed.

For the fail-closed case, run the lifecycle test again with only the ordinary
duckdb library in a fresh process. It verifies that the capability is absent and
managed startup fails clearly. Host/runtime tests skip on that dependency.
Run both dependency variants in CI: a guarded build passing managed tests must
not replace the stock-dependency absence check.
